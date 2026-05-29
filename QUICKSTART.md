# NetSentry Sensor — Quick Start

## System Requirements

| | Minimum | Recommended |
|---|---|---|
| RAM | 2 GB | 4 GB |
| Disk | 5 GB | 20 GB |
| CPU | 2 cores | 4 cores |
| OS | Ubuntu 22.04+ / Debian 12+ | Same |
| Arch | amd64 or arm64 | Same |

---

## 1. Clone and configure

```bash
git clone https://github.com/yourorg/netsentry-sensor.git
cd netsentry-sensor
cp .env.example .env
```

Edit `.env` — minimum required:

```bash
API_KEY=<from-your-cloud-console>
VPS_PUBLIC_IP=<cloud-server-public-ip>
WG_PRIVATE_KEY=<output-of-wg-genkey>
WG_VPS_PUBLIC_KEY=<cloud-wireguard-public-key>
VPS_API_URL=https://your-netsentry-cloud.example.com/api/vps
VPS_WS_URL=wss://your-netsentry-cloud.example.com/ws/raspi
PACKET_STREAM_WS_URL=wss://your-netsentry-cloud.example.com/ws/packets
CAPTURE_INTERFACE=eth0         # interface connected to switch mirror port
SURICATA_IFACE=eth0            # same for SPAN topology
MONGO_ROOT_PASSWORD=<random>
REDIS_PASSWORD=<random>
```

Don't have a cloud instance yet? See [docs/CLOUD_SETUP.md](docs/CLOUD_SETUP.md).

---

## 2. Start

```bash
docker compose -f docker-compose.raspi.yml up -d
```

**ARM64 note:** The compose file defaults to `mongo:4.4.18` (ARM64-safe). x86_64 hosts can override: `MONGO_IMAGE=mongo:7.0 docker compose ...`

---

## 3. Verify

```bash
docker compose -f docker-compose.raspi.yml ps          # all containers Running?
docker exec idps-wireguard wg show wg0                 # WireGuard handshake?
tail -f ./data/logs/suricata/eve.json                  # Suricata events?
docker logs idps-raspi-collector-pi --tail 30          # cloud connection?
```

---

## 4. Build from source (optional)

```bash
# Requires Rust stable + libpcap-dev
cargo build --workspace --release

# Cross-compile for arm64 on x86_64
rustup target add aarch64-unknown-linux-gnu
cargo build --workspace --release --target aarch64-unknown-linux-gnu
```

---

## Manage with systemd

```bash
# Install Docker, start stack, and install systemd service
sudo ./setup.sh install

sudo systemctl enable netsentry
sudo systemctl start  netsentry
sudo systemctl status netsentry
journalctl -u netsentry -f
```

---

## Full Documentation

- [docs/SETUP.md](docs/SETUP.md) — detailed deploy runbook
- [docs/SPAN_TOPOLOGY.md](docs/SPAN_TOPOLOGY.md) — switch port mirroring setup
- [docs/WIREGUARD_SETUP.md](docs/WIREGUARD_SETUP.md) — WireGuard key exchange
- [docs/CLOUD_SETUP.md](docs/CLOUD_SETUP.md) — self-hosting the cloud backend
