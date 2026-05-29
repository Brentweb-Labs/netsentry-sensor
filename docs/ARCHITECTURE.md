# NetSentry Sensor — Architecture

## System Overview

```
                        ┌─────────────────────────────────────┐
                        │         NetSentry Cloud              │
                        │                                      │
  ┌──────────────┐      │  ┌──────────────────────────────┐   │
  │   Router /   │      │  │  Traefik (reverse proxy)     │   │
  │   Switch     │      │  │  :80/443 — TLS termination   │   │
  └──────┬───────┘      │  └──────────────┬───────────────┘   │
         │              │                 │                    │
         │ mirror port  │  ┌──────────────▼──────────────┐    │
         ▼              │  │       API Gateway            │    │
  ┌──────────────┐  WS  │  │  • /ws  — WebSocket hub      │    │
  │ Sensor Node  ├──────┼─►│  • /api/vps — REST API       │    │
  │ wg0:10.10.0.2│      │  │  • threat analysis           │    │
  │ eth0 (SPAN)  │◄─────┼──│  • rule generation           │    │
  └──────────────┘  WG  │  │  • MongoDB persist           │    │
                        │  └─────────────────────────────┘    │
                        └─────────────────────────────────────┘

WireGuard tunnel: sensor (10.10.0.2) ──── cloud (10.10.0.1)
  Sensor initiates outbound (bypasses NAT); cloud reaches sensor at 10.10.0.2
```

**Key principle:** The cloud never touches iptables. It detects threats, generates rules, and sends commands to the sensor. Only the sensor applies blocking — it is the only node with visibility into network traffic.

---

## Default Topology — SPAN / Out-of-band

```
[Internet]
    │
[Router / Modem]
    │
[Managed Switch]
    ├─ Port 1 → Wi-Fi Access Point → [Clients]
    ├─ Port 2 → Server / NAS
    └─ Mirror Port → [Sensor eth0]  (passive, receive-only)
                          │
                    WireGuard tunnel
                          │
                     [Cloud VPS]
```

The sensor receives a **mirrored copy** of all switch traffic but is never in the data path. A sensor failure is invisible to users — traffic continues unaffected.

---

## Alternative Topology — Inline Bridge

```
[Internet]
    │
[Modem]
    │ DHCP — dynamic WAN IP
[Sensor eth0]  ← WAN interface (ingress)
    │
    │  IP forwarding (net.ipv4.ip_forward=1)
    │  NAT: MASQUERADE on eth0
    │
[Sensor eth1]  ← LAN interface (egress)  192.168.100.1/24
    │
[Router / Access Point]                  192.168.100.2/24
    │  gateway: 192.168.100.1
    │
[Clients / Wi-Fi]
```

| Parameter | Value |
|---|---|
| WAN interface | `eth0` — connected to modem |
| LAN interface | `eth1` — connected to router/AP |
| Sensor LAN IP | `192.168.100.1/24` |
| DHCP pool | `192.168.100.100 – 192.168.100.200` |
| Router static IP | `192.168.100.2` |
| Router gateway | `192.168.100.1` (sensor) |
| NAT | `iptables MASQUERADE` on `eth0` |
| DHCP server | `isc-dhcp-server` on `eth1` |

Setup: `scripts/setup/setup-bridge-unified.sh [setup|revert|status]`

---

## Services — Edge (Sensor Node)

| Service | Container | Port | Role | Status |
|---|---|---|---|---|
| wireguard | `idps-wireguard` | host | WireGuard VPN client — initiates tunnel to cloud, maintains keepalive | Running |
| mongodb | `idps-mongodb-pi` | 27017 | Edge event storage | Running |
| redis | `idps-redis-pi` | 6379 | Session cache | Running |
| network-filter | `idps-network-filter-pi` | host | iptables DROP enforcement (inline mode) | Running |
| suricata | `idps-suricata-pi` | host | IDS engine, monitors capture interface, writes eve.json | Running |
| raspi-collector | `idps-raspi-collector-pi` | host | Tails eve.json → forwards events to cloud; receives block/rule commands | Running |
| packet-processor | `idps-packet-processor-pi` | host | pcap capture + fail-open WebSocket streaming to cloud `/ws/packets` | Running |
| rule-engine | `idps-rule-engine-pi` | 8094 | Receives Suricata rules from cloud, writes to rules file, reloads Suricata | Running |
| telemetry | `idps-telemetry-pi` | 8096 | Hardware metrics (CPU/mem/disk/temp) — streams to cloud `/api/telemetry` | Running |
| node-exporter | `idps-node-exporter-pi` | 9100 | Prometheus node metrics | Running |
| pi-dashboard | `idps-pi-dashboard` | 80 | Nginx serving local Angular build | Running |

---

## Services — Cloud

All cloud services run on the `idps-net` internal Docker network. Services exposed publicly join the external `proxy` network, where they are discovered by the Traefik reverse proxy.

| Service | Container | Exposed via | Role |
|---|---|---|---|
| api-gateway | `idps-api-gateway-vps` | `<domain>/api/vps`, `/ws` | WebSocket hub + threat analysis + REST API + billing + alerting + reports |
| vps-processor | `idps-vps-processor` | internal (8093) | Sensor connection manager |
| threat-intel | `idps-threat-intel-vps` | internal (8094) | IP reputation — Tor exits + Feodo blocklist, refreshed hourly |
| packet-analyzer | `idps-packet-analyzer-vps` | host network | Deep packet inspection |
| rule-generator | library crate | — | Suricata/iptables rule generation (shared lib) |
| mongodb | `idps-mongodb-vps` | internal only | Central event, rule, and alert storage |
| log-processor | `idps-log-processor-vps` | internal only | Suricata eve.json ingest pipeline |
| console-frontend | `idps-console-frontend` | `<domain>/console` | SaaS management console (Angular) |
| console-api | `idps-console-api` | `<domain>/api/console` | Multi-tenant management API |
| vps-dashboard | `idps-vps-dashboard` | `<domain>` | Operator dashboard (Angular) |

> Redis and Elasticsearch are **not** part of the cloud stack — they were removed to reduce memory footprint. All persistence goes through MongoDB.

> Prometheus and Grafana are managed by a separate monitoring stack (`ops/monitoring/`). The api-gateway exposes a `/metrics` Prometheus endpoint.

**Suricata does not run on the cloud.** The sensor is the inline/passive sensor; its `eve.json` is forwarded by `raspi-collector`. The cloud analyses events and distributes rules back.

**Traefik** runs in a separate compose stack and handles TLS termination for all public routes.

---

## Event Flow

```
Sensor                                     Cloud
  │                                          │
  │  Suricata writes eve.json                │
  │  raspi-collector tails eve.json          │
  │─── POST /api/traffic (single) ──────────►│
  │─── POST /api/traffic/batch  ────────────►│  → stored in MongoDB
  │                                          │
  │  raspi-collector polls /api/health       │
  │─── GET  /api/health ────────────────────►│  (no auth required)
  │                                          │
  │  Cloud detects threat → generates rule   │
  │◄─ WebSocket /ws/raspi: block_command ────│
  │◄─ WebSocket /ws/raspi: rule_update ──────│
  │                                          │
  │  raspi-collector receives WS command     │
  │  → POST /api/v1/block  (network-filter)  │
  │  → POST /api/v1/rules/apply (rule-engine)│
```

All requests from raspi-collector to the cloud carry `X-API-Key: <API_KEY>` header.

---

## Packet Flow

```
1. Packet arrives at managed switch
       │
2. Switch mirrors a copy to sensor's capture interface (SPAN mode)
       │  — OR —
   Packet flows through sensor inline (bridge mode)
       │
3. libpcap captures a copy; packet-processor checks local blocked_ips DashMap
   ├─ IP is blocked → drop silently (sub-millisecond, no cloud needed)
   └─ IP is unknown → serialize to JSON, push to channel (non-blocking try_send)
       │
4. WebSocket streamer sends JSON to cloud /ws/packets
   └─ Cloud unreachable → channel fills, old frames dropped → traffic still flows (fail-open)
       │
5. api-gateway receives packet
   ├─ Source IP in RFC-1918 → skip (LAN traffic)
   └─ Otherwise → threat analysis:
        • Regex scan: SQL injection, XSS, command injection, path traversal, Shellshock
        • Rate counters: DDoS flood detection
        • Distinct-port counter: port scan detection
       │
6. Threat detected:
   a. generate_ip_block_rule() → Suricata rule string
   b. Persist rule to MongoDB
   c. Broadcast block_command  → all connected sensors
   d. Broadcast rule_update    → Suricata rule string to sensor
       │
7. Sensor receives command:
   ├─ block_command  → POST /api/v1/block to network-filter
   │                   → iptables -A INPUT -s <IP> -j DROP
   └─ rule_update    → POST /api/v1/rules/apply to rule-engine
                       → append to /etc/suricata/rules/idps-dynamic.rules
                       → suricatasc -c reload-rules
       │
8. packet-processor also receives block_command via /ws/raspi
   → updates local blocked_ips DashMap
   → future packets from that IP are dropped in step 3 without cloud round-trip
```

---

## Detection Logic

| Threat | Method | Severity | Action |
|---|---|---|---|
| SQL Injection | Regex on payload | 8 | Block if `AUTO_BLOCK_ENABLED=true` |
| XSS | Regex on payload | 7 | Block |
| Command Injection | Regex on payload | 9 | Block |
| Path Traversal | Regex on payload | 7 | Block |
| Shellshock | Regex on payload | 9 | Block |
| DDoS / Flood | Packet rate per IP > threshold | 9 | Block |
| Port Scan | Distinct ports per IP > threshold | 7 | Block |

`AUTO_BLOCK_ENABLED` defaults to `false`. Detection and alerting always run. Automatic iptables enforcement requires `AUTO_BLOCK_ENABLED=true` on the cloud side.

---

## Source Layout

```
src/
├── shared/
│   ├── types/          PacketEvent, AlertEvent, SystemMetrics, ThreatData
│   ├── protocols/      WebSocket message formats (BlockCommand, RuleUpdate, etc.)
│   ├── utils/          IP/CIDR helpers, retry logic, logging init
│   └── config/         EdgeConfig, CloudConfig typed structs
└── services/
    ├── edge/           Sensor-side services
    │   ├── packet-processor/   pcap capture + fail-open WebSocket streaming
    │   ├── raspi-collector/    eve.json tailer + cloud command bridge
    │   ├── network-filter/     iptables enforcement (inline mode)
    │   ├── firewall-forwarder/ router API blocking (SPAN mode)
    │   ├── rule-engine/        Suricata dynamic rule management
    │   └── telemetry/          hardware metrics reporter
    └── cloud/          Cloud-side services (netsentry-cloud repo)
        ├── api-gateway/        threat analysis + WebSocket hub
        ├── rule-generator/     Suricata/iptables rule generation
        ├── packet-analyzer/    deep packet inspection
        └── threat-intel/       IP reputation service

src/tools/
├── dashboard/          Angular local dashboard
└── benchmarks/         performance testing
```

---

## Docker Compose Files

| File | Use for |
|---|---|
| `docker-compose.raspi.yml` | Sensor deployment (all edge services) |
| `docker-compose.span.yml` | SPAN topology overrides (use alongside raspi.yml) |

---

## Traefik Routing (Cloud)

| Incoming path | Middleware | Forwarded to |
|---|---|---|
| `<domain>/api/vps/*` | `idps-strip-vps` — strips `/api/vps` prefix | `api-gateway:8080/api/*` |
| `<domain>/api/prevention/*` | (none) | `api-gateway:8080/api/prevention/*` |
| `<domain>/ws` | (none) | `api-gateway:8080/ws` |
| `<domain>/api/console` | (none) | `console-api:8095/api/console` |
| `<domain>/console` | `idps-strip-console` | `console-frontend:80/` |
| `<domain>` (catch-all) | IP allowlist | `vps-dashboard:80` |

The `idps-api` router has `priority=20`; the `idps-dashboard` catch-all has `priority=10`.
All middlewares must be referenced with the `@docker` provider suffix in Traefik v3.
