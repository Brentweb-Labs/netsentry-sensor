# IDPS — Architecture

## System Overview

```
                        ┌─────────────────────────────────────┐
                        │           VPS (Cloud)               │
                        │        178.104.6.176                │
                        │        wg0: 10.10.0.1               │
                        │                                     │
  ┌──────────────┐      │  ┌──────────────────────────────┐  │
  │    Router /  │      │  │  Traefik (external stack)    │  │
  │    Modem     │      │  │  :80/443 — TLS termination   │  │
  └──────┬───────┘      │  │  proxy network               │  │
         │ all traffic  │  └──────────────┬───────────────┘  │
         ▼              │                 │ idps-net          │
  ┌──────────────┐  WS  │  ┌─────────────▼──────────────┐   │
  │ Raspberry Pi ├──────┼─►│       API Gateway           │   │
  │ 192.168.1.47 │      │  │  • /ws  — WebSocket hub     │   │
  │ wg0:10.10.0.2│      │  │  • /api/vps — REST API       │   │
  │ eth0 (LAN)   │      │  │  • threat analysis           │   │
  │ eth1 (mesh)  │◄─────┼──│  • rule generation           │   │
  │ br0 (bridge) │ WG   │  │  • MongoDB persist           │   │
  └──────────────┘      │  └────────────────────────────┘   │
         │              │                                     │
         ▼              └─────────────────────────────────────┘
  [rest of network]

WireGuard tunnel: Pi (10.10.0.2) ──── VPS (10.10.0.1)
  Pi initiates outbound (bypasses NAT), VPS reaches Pi at 10.10.0.2
```

**Key principle:** The VPS never touches iptables. It detects threats, generates rules, and sends commands to the Pi. Only the Pi applies blocking — because only the Pi sits inline on the physical network.

---

## Network Layout

```
[Internet]
    │
[Router/Modem]
    │
[Pi eth0] ← all inbound traffic enters here
    │
[Pi eth1 / br0] → switch / wifi AP → [clients]
```

The Pi acts as a transparent network bridge. Clients need no reconfiguration. If the VPS is unreachable the Pi keeps forwarding traffic normally (fail-open). Only IPs that have already been flagged are dropped from the in-memory cache.

---

## Bridge Configuration (Pi)

```
[Internet]
    │
[Modem]
    │ DHCP — dynamic WAN IP
[Pi eth0]  ← WAN interface (ingress)
    │
    │  IP forwarding (net.ipv4.ip_forward=1)
    │  NAT: MASQUERADE on eth0
    │
[Pi eth1]  ← LAN interface (egress)  192.168.100.1/24
    │
[Router / TP-Link Deco]              192.168.100.2/24
    │  gateway: 192.168.100.1
    │  DNS:     8.8.8.8, 1.1.1.1
    │
[Clients / Wi-Fi]
```

| Parameter | Value |
|---|---|
| WAN interface | `eth0` — connected to modem, IP via DHCP |
| LAN interface | `eth1` — connected to router |
| Pi LAN IP | `192.168.100.1/24` |
| LAN subnet | `192.168.100.0/24` |
| DHCP pool | `192.168.100.100 – 192.168.100.200` |
| Router static IP | `192.168.100.2` |
| Router gateway | `192.168.100.1` (Pi) |
| Router DNS | `8.8.8.8`, `1.1.1.1` |
| NAT | `iptables MASQUERADE` on `eth0` |
| DHCP server | `isc-dhcp-server` on `eth1` |
| Forwarding | `eth1 → eth0` ACCEPT, `eth0 → eth1` ESTABLISHED/RELATED |

Setup/teardown: `scripts/setup/setup-bridge-unified.sh [setup|revert|status|troubleshoot]`

---

## Services — Edge (Pi 192.168.1.47 / WireGuard 10.10.0.2)

| Service | Container | Port | Role | Status |
|---|---|---|---|---|
| wireguard | `idps-wireguard` | host | WireGuard VPN client — initiates tunnel to VPS, maintains keepalive | Running |
| mongodb | `idps-mongodb-pi` | 27017 | Edge event storage (ARM64, mongo 4.4.18) | Running |
| redis | `idps-redis-pi` | 6379 | Session cache | Running |
| network-filter | `idps-network-filter-pi` | host | iptables DROP enforcement | Running |
| suricata | `idps-suricata-pi` | host | IDS engine, monitors br0, writes eve.json | Running |
| raspi-collector | `idps-raspi-collector-pi` | host | Tails eve.json → forwards events to VPS; receives block/rule commands from VPS | Running |
| packet-processor | `idps-packet-processor-pi` | host | pcap capture + fail-open WebSocket streaming to VPS `/ws/packets` | Running |
| rule-engine | `idps-rule-engine-pi` | host (8094) | Receives Suricata rules from VPS, writes to rules file, reloads Suricata | Running |
| ids-pi | `idps-ids-pi` | host (8085) | Python edge security scanner (safe hours only) | Running — health endpoint only |
| telemetry | `idps-telemetry-pi` | 8096 | Hardware metrics (CPU/mem/disk/temp) — streams to VPS `/api/telemetry` | Running |
| node-exporter | `idps-node-exporter-pi` | 9100 | Prometheus node metrics | Running |
| pi-dashboard | `idps-pi-dashboard` | 80 | Nginx serving Angular build | Running |

---

## Services — Cloud (VPS 178.104.6.176)

All cloud services run on the `idps-net` internal Docker network. Services that need to be reachable via the public domain also join the external `proxy` network, where they are discovered by the Traefik instance that runs in a separate stack.

| Service | Container | Exposed via | Role |
|---|---|---|---|
| api-gateway | `idps-api-gateway-vps` | `idps.brentweb.eu/api/vps`, `/ws` | WebSocket hub + threat analysis + REST API + billing + alerting + reports |
| vps-processor | `idps-vps-processor-vps` | internal (8093) | Raspi connection manager |
| threat-intel | `idps-threat-intel-vps` | internal (8094) | IP reputation — Tor exits + Feodo blocklist, refreshed hourly |
| packet-analyzer | `idps-packet-analyzer-vps` | host network | Deep packet inspection |
| rule-generator | library crate | — | Suricata/iptables rule generation (shared lib) |
| mongodb | `idps-mongodb-vps` | internal only | Central event, rule, and alert storage (v8.0, db: `idps_database`) |
| log-processor | `idps-log-processor-vps` | internal only | Suricata eve.json ingest pipeline |
| vps-dashboard | `idps-vps-dashboard` | `idps.brentweb.eu` | Nginx serving Angular build |

> Redis and Elasticsearch are **not** part of the cloud stack — they were removed to reduce memory footprint. All persistence goes through MongoDB (`idps_database`).

> Prometheus and Grafana are **not** managed by `docker-compose.vps.yml`. Their configuration lives in `ops/monitoring/` and must be run as a separate monitoring stack. The api-gateway exposes a `/metrics` Prometheus endpoint.

**Suricata does not run on the VPS.** The Pi is the inline sensor; its eve.json is forwarded to the VPS by raspi-collector. The VPS analyses those events and generates rules sent back to the Pi.

**Traefik** runs in a separate compose stack (not managed by this repo) and handles ports 80/443, TLS termination, and HTTP→HTTPS redirect for all `*.brentweb.eu` domains.

---

## Event Flow (current deployment)

```
Pi                                         VPS
  │                                          │
  │  Suricata writes eve.json                │
  │  raspi-collector tails eve.json          │
  │─── POST /api/traffic (single) ──────────►│
  │─── POST /api/traffic/batch  ────────────►│  → stored in MongoDB idps.events
  │                                          │
  │  raspi-collector polls /api/health       │
  │─── GET  /api/health ────────────────────►│  (no auth required)
  │                                          │
  │  VPS detects threat → generates rule     │
  │◄─ WebSocket /ws/raspi: block_command ────│
  │◄─ WebSocket /ws/raspi: rule_update ──────│
  │                                          │
  │  raspi-collector receives WS command     │
  │  → POST /api/v1/block  (network-filter)  │
  │  → POST /api/v1/rules/apply (rule-engine)│
```

All requests from raspi-collector to the VPS carry `X-API-Key: <API_KEY>` header.
`/api/traffic` and `/api/traffic/batch` map through Traefik:
`https://idps.brentweb.eu/api/vps/traffic` → (strip `/api/vps`) → `api-gateway:8080/api/traffic`

---

## Packet Flow (full — when packet-processor is deployed)

```
1. Packet arrives at Pi eth0
       │
2. libpcap captures a copy (passive — packet still flows through)
       │
3. packet-processor checks local blocked_ips DashMap
   ├─ IP is blocked → drop silently (sub-millisecond, no VPS needed)
   └─ IP is unknown → serialize to JSON, push to channel (non-blocking try_send)
       │
4. WebSocket streamer sends JSON to VPS /ws/packets
   └─ VPS unreachable → channel fills, old frames dropped → traffic still flows (fail-open)
       │
5. api-gateway receives packet
   ├─ Source IP in RFC-1918 whitelist → skip (LAN traffic)
   └─ Otherwise → threat analysis:
        • Regex scan: SQL injection, XSS, command injection, path traversal, Shellshock
        • Rate counters: DDoS flood (packets/sec per IP)
        • Distinct-port counter: port scan detection
       │
6. Threat detected:
   a. generate_ip_block_rule() → Suricata rule string
   b. Persist rule to MongoDB security_rules collection
   c. Broadcast block_command  → all connected Pi /ws/raspi clients
   d. Broadcast rule_update    → Suricata rule string to Pi
       │
7. Pi raspi-collector receives command:
   ├─ block_command  → POST /api/v1/block to network-filter
   │                   → iptables -A INPUT -s <IP> -j DROP
   └─ rule_update    → POST /api/v1/rules/apply to rule-engine
                       → append to /etc/suricata/rules/idps-dynamic.rules
                       → suricatasc -c reload-rules
       │
8. packet-processor also receives block_command via /ws/raspi
   → updates local blocked_ips DashMap
   → future packets from that IP are dropped in step 3 without VPS round-trip
```


---

## Data Flow

```
Pi                         VPS                        Storage
  │                          │                            │
  │── traffic events ───────►│── persist ────────────────►│ MongoDB idps_database.events
  │                          │── threat detected          │
  │                          │── persist rule ───────────►│ MongoDB idps_database.security_rules
  │                          │── persist alert ──────────►│ MongoDB idps_database.alerts
  │◄─ block_command ─────────│                            │
  │◄─ rule_update ───────────│                            │
  │                          │                            │
  │── telemetry (local) ─────X  (not yet streaming)       │
  │                          │                            │
  │                          │── WebSocket updates ──────►│ Angular Dashboard
```

---

## Detection Logic (api-gateway)

| Threat | Method | Threat level | Action |
|---|---|---|---|
| SQL Injection | Regex on payload | 8 | Block if `AUTO_BLOCK_ENABLED` |
| XSS | Regex on payload | 7 | Block |
| Command Injection | Regex on payload | 9 | Block |
| Path Traversal | Regex on payload | 7 | Block |
| Shellshock | Regex on payload | 9 | Block |
| DDoS / Flood | Packet rate per IP > threshold | 9 | Block |
| Port Scan | Distinct ports per IP > threshold | 7 | Block |

`AUTO_BLOCK_ENABLED` defaults to `false`. Detection and alerting always run. Set `AUTO_BLOCK_ENABLED=true` to enable automatic iptables enforcement on the Pi.

---

## Infrastructure Details

| | VPS | Pi |
|---|---|---|
| Hardware | Hetzner CPX42 — 8 vCPU, 16 GB RAM, x86_64 | Raspberry Pi 4 — 4 GB RAM, ARM64 |
| IP (public) | 178.104.6.176 | 192.168.1.47 (behind NAT, not directly routable) |
| IP (WireGuard) | 10.10.0.1 | 10.10.0.2 |
| Docker networks | `idps-net` (internal) + `proxy` (external Traefik) | `idps-net` (internal) + host network for inline services |
| MongoDB version | 8.0 | 4.4.18 (ARMv8.0-A max — RPi4 Cortex-A72 limitation) |
| Rust version | 1.94 (bookworm) | 1.94 (bookworm, cross-compiled) |
| Pi → VPS connectivity | VPS reachable at 178.104.6.176 (public) or 10.10.0.1 (WireGuard) | Connects outbound; VPS uses `RASPI_ENDPOINT=http://10.10.0.2:8080` |
| WireGuard | Peer config, static — Pi's public key registered as peer | Containerised (`idps-wireguard`), env-var-driven, self-monitoring |

---

## Source Layout

```
src/
├── shared/
│   ├── types/          PacketEvent, AlertEvent, SystemMetrics, ThreatData
│   ├── protocols/      protocol parsers and message formats
│   ├── utils/          IP CIDR helper, retry logic, logging init (complete)
│   └── config/         EdgeConfig, CloudConfig typed structs (complete)
└── services/
    ├── edge/           Raspberry Pi services
    │   ├── packet-processor/   pcap capture + fail-open streaming (code-complete, not in compose)
    │   ├── raspi-collector/    eve.json tailer + VPS command bridge (running)
    │   ├── network-filter/     iptables enforcement (running)
    │   ├── rule-engine/        Suricata dynamic rule management (code-complete, not in compose)
    │   ├── ids-pi/             Python scheduled scanner (running, minimal)
    │   └── telemetry/          hardware metrics reporter (running, local only)
    └── cloud/          VPS services
        ├── api-gateway/        threat analysis + WebSocket hub + event ingest
        ├── rule-generator/     Suricata/iptables rule generation (library)
        ├── packet-analyzer/    deep packet inspection
        └── threat-intel/       IP reputation service (stubbed)

src/tools/
├── dashboard/          Angular 21 dashboard (TailwindCSS, ApexCharts)
├── cli/                management CLI
└── benchmarks/         performance testing

raspi/
└── wireguard/          WireGuard container (Alpine + wireguard-tools, env-var-driven)
```

---

## Docker Compose Files

| File | Use for |
|---|---|
| `docker-compose.vps.yml` | VPS deployment (all cloud services) |
| `docker-compose.raspi.yml` | Pi deployment (all edge services including WireGuard) |

---

## Traefik Routing (VPS)

| Incoming path | Middleware | Forwarded to |
|---|---|---|
| `idps.brentweb.eu/api/vps/*` | `idps-strip-vps` — strips `/api/vps` prefix | `api-gateway:8080/api/*` |
| `idps.brentweb.eu/api/prevention/*` | (none — passed as-is) | `api-gateway:8080/api/prevention/*` |
| `idps.brentweb.eu/ws` | (none) | `api-gateway:8080/ws` |
| `idps.brentweb.eu` (catch-all) | (none) | `vps-dashboard:80` |
| `grafana.idps.brentweb.eu` | (none) | `grafana:3000` |

The `idps-api` router has `priority=20`; the `idps-dashboard` catch-all has `priority=10`.
All middlewares must be referenced with the `@docker` provider suffix in Traefik v3.
