# NetSentry Sensor

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Language: Rust](https://img.shields.io/badge/language-Rust-orange.svg)](https://www.rust-lang.org/)
[![Arch: amd64 / arm64](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-blue.svg)](#requirements)

The **open-source edge component** of the NetSentry platform. A high-throughput network security monitoring agent written entirely in Rust that runs on any Linux system, captures network traffic, detects threats via [Suricata](https://suricata.io/), and forwards telemetry to a NetSentry Cloud instance over an encrypted WireGuard tunnel.

> **This repo is the sensor only.** The cloud backend is a separate, private repository. See [Connecting to a Cloud](#connecting-to-a-cloud) for how to pair a sensor with a cloud instance — either the hosted SaaS or your own self-hosted deployment.

---

## How it works

```
[Internet]
    │
[Router / Modem]
    │
[Managed Switch]  ─── mirror port ───► [Sensor (this repo)]
    │                                        │ WireGuard tunnel
    ├─ Port 1 → Wi-Fi Access Point           ▼
    ├─ Port 2 → Server / NAS          [NetSentry Cloud]
    └─ Port N → Clients               alerts, rules, dashboard
```

The sensor sits **out-of-band** (default) on a managed switch mirror port. It receives a copy of all network traffic but is never in the packet path — a sensor failure causes zero network disruption. The cloud analyses the traffic, generates Suricata/iptables rules, and sends them back to the sensor in real time over a WebSocket channel.

**Inline bridge mode** (alternative) places the sensor directly between the modem and router for stronger enforcement. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Features

- **Fail-open** — sensor failure never takes down the network
- **Suricata IDS** — continuous deep-packet inspection; dynamic rules pushed from cloud
- **WireGuard tunnel** — sensor initiates outbound; bypasses NAT with no firewall changes needed
- **Real-time blocking** — cloud sends `block_command` over WebSocket; `network-filter` applies iptables in milliseconds
- **Hardware telemetry** — CPU, memory, disk streamed to cloud dashboard
- **Multi-arch** — native builds for `amd64` and `arm64` (Raspberry Pi 4/5, other SBCs)
- **Docker Compose** — single `docker compose up -d` deploys the entire edge stack

---

## Requirements

| | SPAN (default) | Inline bridge |
|---|---|---|
| **Hardware** | Any Linux system with 4 GB+ RAM | Linux system with **two** Ethernet interfaces |
| **OS** | Ubuntu 22.04+ / Debian 12+ / any modern Linux | Same |
| **Network** | Managed switch with port mirroring support | Modem directly connected to eth0 |
| **Docker** | Docker 24+ with Compose plugin | Same |
| **Cloud** | A NetSentry Cloud instance (SaaS or self-hosted) | Same |

**Supported architectures:** `linux/amd64`, `linux/arm64`

Common hardware: any x86_64 server/mini PC, Raspberry Pi 4/5, ODROID, Jetson Nano.

---

## Quick Start

### 1. Prepare your environment file

```bash
git clone https://github.com/yourorg/netsentry-sensor.git
cd netsentry-sensor
cp .env.example .env
```

Edit `.env` and set the required variables:

```bash
API_KEY=<sensor-api-key-from-your-cloud-console>
VPS_PUBLIC_IP=<your-cloud-server-public-ip>
WG_PRIVATE_KEY=<output-of-wg-genkey>
WG_VPS_PUBLIC_KEY=<vps-wireguard-public-key>
VPS_API_URL=https://your-netsentry-cloud.example.com/api/vps
VPS_WS_URL=wss://your-netsentry-cloud.example.com/ws/raspi
PACKET_STREAM_WS_URL=wss://your-netsentry-cloud.example.com/ws/packets
```

> See [docs/WIREGUARD_SETUP.md](docs/WIREGUARD_SETUP.md) for the WireGuard key exchange walkthrough.

### 2. Configure your switch port mirroring

Point your switch's mirror/SPAN destination port at the sensor's Ethernet interface. The exact steps vary by switch model — see [docs/SPAN_TOPOLOGY.md](docs/SPAN_TOPOLOGY.md) for vendor-specific instructions (Netgear, TP-Link, Ubiquiti, Cisco).

### 3. Start the sensor stack

```bash
docker compose -f docker-compose.raspi.yml up -d
```

### 4. Verify

```bash
# All containers running?
docker compose -f docker-compose.raspi.yml ps

# WireGuard tunnel established?
docker exec idps-wireguard wg show wg0

# Suricata seeing traffic?
tail -f ./data/logs/suricata/eve.json

# Cloud connection healthy?
docker logs idps-raspi-collector-pi --tail 30
```

The sensor should appear as **Online** in your cloud dashboard within 30 seconds.

---

## Edge Services

| Service | Container | Port | Role |
|---|---|---|---|
| `wireguard` | `idps-wireguard` | host | Outbound WireGuard tunnel to cloud |
| `suricata` | `idps-suricata-pi` | host | IDS engine — monitors capture interface, writes `eve.json` |
| `raspi-collector` | `idps-raspi-collector-pi` | 8080 | Tails `eve.json` → cloud; receives block/rule commands |
| `packet-processor` | `idps-packet-processor-pi` | 8091 | libpcap capture + fail-open WebSocket stream to cloud |
| `network-filter` | `idps-network-filter-pi` | 8092 | iptables DROP enforcement |
| `rule-engine` | `idps-rule-engine-pi` | 8094 | Receives Suricata rules, writes file, reloads engine |
| `telemetry` | `idps-telemetry-pi` | 8096 | Hardware metrics reporter |
| `mongodb` | `idps-mongodb-pi` | 27017 | Edge event storage |
| `redis` | `idps-redis-pi` | 6379 | Local session cache |
| `node-exporter` | `idps-node-exporter-pi` | 9100 | Prometheus node metrics |
| `pi-dashboard` | `idps-pi-dashboard` | 80 | Local Nginx dashboard |

---

## Connecting to a Cloud

The sensor requires a running NetSentry Cloud backend. You have two options:

### Option A — NetSentry SaaS (hosted)

Sign up at [netsentry.io](https://netsentry.io) (coming soon). The cloud console will give you an `API_KEY` and the WireGuard public key to put in `.env`.

### Option B — Self-hosted cloud

Deploy the NetSentry Cloud stack on your own server. See [docs/CLOUD_SETUP.md](docs/CLOUD_SETUP.md) for infrastructure requirements and configuration.

> The cloud repository is private. Contact [brentweb.eu@gmail.com](mailto:brentweb.eu@gmail.com) for early access if you want to run the full self-hosted stack.

---

## Topologies

### SPAN / Out-of-band (default)

Passive monitoring. The sensor connects to a switch mirror port. Zero network disruption on sensor failure.

```
[Router] → [Managed Switch] ──────────► [Clients]
                │
           mirror port
                │
           [Sensor eth0]  ──(WireGuard)──► [Cloud]
```

### Inline Bridge

Stronger enforcement — all traffic flows through the sensor. Requires two Ethernet interfaces.

```
[Modem] → [Sensor eth0/eth1] → [Router / Access Point] → [Clients]
                │
           (WireGuard)
                │
            [Cloud]
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for full topology details and [docs/PI_BRIDGE_SETUP.md](docs/PI_BRIDGE_SETUP.md) for the bridge setup guide.

---

## Documentation

| Doc | Contents |
|---|---|
| [docs/SETUP.md](docs/SETUP.md) | Step-by-step deploy runbook |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Components, topologies, event flows |
| [docs/SPAN_TOPOLOGY.md](docs/SPAN_TOPOLOGY.md) | SPAN/out-of-band setup (switch port mirroring) |
| [docs/PI_BRIDGE_SETUP.md](docs/PI_BRIDGE_SETUP.md) | Inline bridge network configuration |
| [docs/WIREGUARD_SETUP.md](docs/WIREGUARD_SETUP.md) | WireGuard key exchange guide |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-2 ops, env vars, API endpoints |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Build, test, contribute |
| [docs/CLOUD_SETUP.md](docs/CLOUD_SETUP.md) | Self-hosted cloud infrastructure requirements |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contribution guidelines |

---

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get started, the code structure, and the PR process.

---

## License

MIT — see [LICENSE](LICENSE).
