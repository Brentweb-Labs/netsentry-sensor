# NetSentry Sensor — Documentation

## Quick Navigation

| Doc | Contents |
|---|---|
| [SETUP.md](SETUP.md) | Step-by-step deployment guide |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture, topologies, event flows |
| [SPAN_TOPOLOGY.md](SPAN_TOPOLOGY.md) | Default: passive out-of-band monitoring via switch port mirroring |
| [PI_BRIDGE_SETUP.md](PI_BRIDGE_SETUP.md) | Alternative: inline bridge between modem and router |
| [WIREGUARD_SETUP.md](WIREGUARD_SETUP.md) | WireGuard key exchange and tunnel configuration |
| [OPERATIONS.md](OPERATIONS.md) | Env vars, API endpoints, day-2 commands, troubleshooting |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Build, test, and contribute |
| [CLOUD_SETUP.md](CLOUD_SETUP.md) | Self-hosting the cloud backend (server requirements, WireGuard, Traefik) |

---

## Platform Overview

NetSentry is an open-core network security platform built around three components:

1. **Sensor** (this repo — open source): Rust edge agent that monitors network traffic, runs Suricata IDS, and communicates with the cloud over WireGuard.

2. **Cloud backend** (private repo): Rust + NestJS services that receive traffic events, analyse threats, generate detection rules, and push block commands back to sensors.

3. **SaaS console** (part of cloud): Angular multi-tenant management UI for provisioning sensors, configuring alerts, managing users, and viewing reports.

The sensor is the only public component. Businesses can deploy it on their own infrastructure and connect it to either:
- The hosted **NetSentry SaaS** (coming soon)
- Their own **self-hosted cloud** instance (see [CLOUD_SETUP.md](CLOUD_SETUP.md))

---

## Supported Topologies

| Mode | Description | Hardware needed |
|---|---|---|
| **SPAN / Out-of-band** (default) | Passive — mirror port on managed switch. Zero network disruption on sensor failure. | 1 NIC, managed switch |
| **Inline Bridge** | Active — sensor sits between modem and router. Strongest enforcement. | 2 NICs |

---

## Quick Links

- [Open an issue](https://github.com/yourorg/netsentry-sensor/issues)
- [CONTRIBUTING.md](../CONTRIBUTING.md) — how to contribute
- [CLOUD_SETUP.md](CLOUD_SETUP.md) — self-hosting / SaaS guide
