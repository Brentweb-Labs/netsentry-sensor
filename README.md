# NetSentry Sensor (`netsentry-sensor`)

NetSentry Sensor is the open-source edge component of the NetSentry platform — a high-throughput network security monitoring agent built entirely in Rust. It runs on a Raspberry Pi 4 that sits inline between your modem and the rest of your network, intercepting traffic and forwarding structured threat telemetry to the [NetSentry Cloud](https://github.com/yourorg/netsentry-cloud) over an encrypted WireGuard tunnel.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Language: Rust](https://img.shields.io/badge/language-Rust-orange.svg)](https://www.rust-lang.org/)

---

## Key Features

- **Inline transparent bridge** — sits between modem and router; clients need zero reconfiguration
- **Suricata integration** — continuously tails `eve.json` for deep-packet-inspection alerts
- **Fail-open resilience** — if the VPS becomes unreachable, traffic flows through uninterrupted; only already-blocked IPs are dropped from the in-memory cache
- **WireGuard tunnel** — Pi initiates outbound; bypasses NAT without firewall changes; VPS reaches Pi at `10.10.0.2`
- **Automatic blocking** — on threat detection the VPS sends `block_command` back over WebSocket; `network-filter` applies iptables rules in milliseconds
- **Hardware telemetry** — CPU, memory, disk, and temperature streamed to the VPS dashboard

---

## Architecture

```
[Modem]
   │
[Pi eth0]  ← passive pcap + Suricata monitor here
   │  br0
[Pi eth1]  → router / switch → clients
```

```
Pi (10.10.0.2)                         VPS (10.10.0.1)
   │                                         │
   │── POST /api/traffic/batch ─────────────►│  Suricata alerts → MongoDB
   │── WS /ws/packets ─────────────────────►│  Raw packet stream
   │                                         │
   │◄─ WS /ws/raspi: block_command ──────────│  iptables DROP via network-filter
   │◄─ WS /ws/raspi: rule_update ────────────│  Suricata rule reload via rule-engine
   │                                         │
   │── GET /api/health ──────────────────────│  Keep-alive / reconnect polling
   │── POST /api/telemetry ─────────────────►│  CPU/mem/disk/temp metrics
```

---

## Edge Services (Raspberry Pi)

| Service | Container | Port | Role |
|---|---|---|---|
| `wireguard` | `idps-wireguard` | host | Outbound WireGuard tunnel to VPS |
| `suricata` | `idps-suricata-pi` | host | IDS engine — monitors `br0`, writes `eve.json` |
| `raspi-collector` | `idps-raspi-collector-pi` | host | Tails `eve.json` → VPS; receives block/rule commands |
| `packet-processor` | `idps-packet-processor-pi` | host | libpcap capture + fail-open WebSocket stream |
| `network-filter` | `idps-network-filter-pi` | host | iptables DROP enforcement |
| `rule-engine` | `idps-rule-engine-pi` | 8094 | Receives Suricata rules, writes file, reloads engine |
| `telemetry` | `idps-telemetry-pi` | 8096 | Hardware metrics reporter |
| `mongodb` | `idps-mongodb-pi` | 27017 | Edge event storage (ARM64 — mongo 4.4.18) |
| `redis` | `idps-redis-pi` | 6379 | Local session cache |
| `node-exporter` | `idps-node-exporter-pi` | 9100 | Prometheus node metrics |
| `pi-dashboard` | `idps-pi-dashboard` | 80 | Nginx serving Angular build |

---

## Quick Start

### Option A — One-line installer (recommended for production)

```bash
curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup/install.sh | sudo bash
```

The installer:
1. Installs Docker, `wireguard-tools`, and `iptables-persistent`
2. Downloads `docker-compose.raspi.yml` and setup scripts to `/opt/netsentry/`
3. Prompts for your `VPS_ENDPOINT` URL
4. Generates a WireGuard keypair and prints the **public key** — paste it into your VPS peer config
5. Installs and starts the `idps-bridge` systemd service

### Option B — Manual setup

```bash
# 1. One-time: create the network bridge
sudo ./scripts/setup/setup-bridge-unified.sh

# 2. Configure environment
cp .env.example .env
# edit .env: set VPS_ENDPOINT, WG_PRIVATE_KEY, WG_VPS_PUBLIC_KEY, API_KEY

# 3. Start edge stack
docker compose -f docker-compose.raspi.yml up -d
```

See [docs/SETUP.md](docs/SETUP.md) for the full guide.

---

## Requirements

- Raspberry Pi 4 (4 GB RAM recommended) running Raspberry Pi OS / Ubuntu 22.04 (arm64)
- Two Ethernet interfaces (`eth0` — WAN, `eth1` — LAN)
- Docker 24+ with the Compose plugin
- A running [NetSentry Cloud](https://github.com/yourorg/netsentry-cloud) VPS instance

---

## Documentation

| Doc | What's in it |
|---|---|
| [docs/SETUP.md](docs/SETUP.md) | Step-by-step deploy runbook |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Components, event flows, network layout |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-2 ops, env vars, API endpoints, troubleshooting |
| [docs/PI_BRIDGE_SETUP.md](docs/PI_BRIDGE_SETUP.md) | Network bridge + WireGuard pairing guide |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Build, test, contribute |

---

## License

MIT — see [LICENSE](LICENSE).
