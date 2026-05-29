# Setup Guide

## Prerequisites

### Sensor (this repo)

- **Linux system** with 4 GB+ RAM (x86_64 or arm64 — Raspberry Pi 4/5 works fine)
- Docker 24+ with the Compose plugin (`docker compose version`)
- For **SPAN topology** (default): one Ethernet interface connected to a managed switch mirror port
- For **Inline bridge topology**: two Ethernet interfaces (`eth0` — WAN, `eth1` — LAN)
- A running NetSentry Cloud instance — see [Cloud Setup](#cloud-setup) below

### Cloud

- See [docs/CLOUD_SETUP.md](CLOUD_SETUP.md) for full requirements.
- Short version: a Linux VPS with 4 GB+ RAM, Docker, and a domain with a wildcard or dedicated DNS A record pointing at it.

---

## Cloud Setup

> Skip this section if you are connecting to the hosted NetSentry SaaS.

The cloud backend lives in a separate private repository (`netsentry-cloud`). If you are building your own SaaS or self-hosting the full stack, you need to deploy the cloud first.

```bash
# On your cloud server
git clone <netsentry-cloud-repo>  # contact for access
cd netsentry-cloud
cp .env.example .env
# Fill in: DOMAIN, ALLOWED_IP, MONGO_ROOT_PASSWORD, JWT_SECRET, ADMIN_PASSWORD
./install.sh

# Ensure the external Traefik proxy network exists
docker network create proxy   # only needed once per host

docker compose -f docker-compose.yml up -d
```

Verify:
```bash
docker compose ps
curl https://<your-domain>/health
```

> Traefik must be running in a separate stack with the `proxy` external network created before the cloud stack starts.

Once the cloud is up, note the **WireGuard public key** (`publickey` file in the cloud repo root) and the **API key** from the console — you will need both when configuring the sensor.

---

## Sensor Setup

### Step 1 — Clone and configure

```bash
git clone https://github.com/yourorg/netsentry-sensor.git
cd netsentry-sensor
cp .env.example .env
```

Edit `.env`. The required variables are:

| Variable | What to set |
|---|---|
| `API_KEY` | Sensor API key from your cloud console |
| `VPS_PUBLIC_IP` | Public IP of your cloud server |
| `WG_PRIVATE_KEY` | Output of `wg genkey` run on this machine |
| `WG_VPS_PUBLIC_KEY` | Cloud WireGuard public key |
| `VPS_API_URL` | `https://<your-domain>/api/vps` |
| `VPS_WS_URL` | `wss://<your-domain>/ws/raspi` |
| `PACKET_STREAM_WS_URL` | `wss://<your-domain>/ws/packets` |
| `CAPTURE_INTERFACE` | Ethernet interface connected to mirror port (SPAN) or WAN (inline) |
| `SURICATA_IFACE` | Same as `CAPTURE_INTERFACE` (for SPAN); `br0` for inline bridge |
| `MONGO_ROOT_PASSWORD` | Change from the default before deploying |
| `REDIS_PASSWORD` | Change from the default before deploying |

See [docs/WIREGUARD_SETUP.md](WIREGUARD_SETUP.md) for the full WireGuard key exchange walkthrough.

### Step 2 — Configure switch port mirroring (SPAN topology)

Access your switch's web UI and set up a mirror/SPAN session:

- **Source ports:** all ports carrying traffic you want to monitor (typically router uplink + access point)
- **Mirror destination port:** the port where your sensor is physically connected

See [docs/SPAN_TOPOLOGY.md](SPAN_TOPOLOGY.md) for vendor-specific steps and verification commands.

### Step 3 — Start the sensor stack

```bash
docker compose -f docker-compose.raspi.yml up -d
```

For SPAN topology the base compose file is sufficient. For inline bridge, also run the bridge setup script first:

```bash
sudo ./setup.sh bridge
docker compose -f docker-compose.raspi.yml up -d
```

### Step 4 — Register WireGuard peer on the cloud

After generating your sensor's WireGuard keypair, register the sensor's **public key** as a peer on the cloud:

```bash
# On the cloud server
sudo wg set wg0 peer <SENSOR_WG_PUBKEY> allowed-ips 10.10.0.2/32 persistent-keepalive 25
sudo wg-quick save wg0
```

Or use the cloud console if it supports WireGuard peer management.

### Step 5 — Verify

```bash
# All containers up?
docker compose -f docker-compose.raspi.yml ps

# WireGuard tunnel active?
docker exec idps-wireguard wg show wg0

# Traffic arriving on capture interface?
sudo tcpdump -i <CAPTURE_INTERFACE> -c 5

# Suricata writing events?
tail -f ./data/logs/suricata/eve.json

# Cloud connection OK?
docker logs idps-raspi-collector-pi --tail 30
```

The sensor should appear as **Online** in the cloud dashboard within 30 seconds of a successful WireGuard handshake.

---

## One-line Installer

A convenience installer script is available for automated deployments:

```bash
curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup.sh | sudo bash
```

The installer:
1. Installs Docker, `wireguard-tools`, and `iptables-persistent`
2. Downloads the repo to `/opt/netsentry/`
3. Prompts for `VPS_API_URL` and WireGuard keys
4. Generates credentials and creates `.env`
5. Installs and starts the `netsentry` systemd service for auto-restart on boot

Manage afterwards:
```bash
systemctl status netsentry
journalctl -u netsentry -f
cd /opt/netsentry && docker compose -f docker-compose.raspi.yml up -d
```

---

## Common Commands

```bash
./setup.sh status
./setup.sh up
./setup.sh diagnose
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| No events in `eve.json` | Check `SURICATA_IFACE` matches your capture interface; run `fix-eve`; generate test traffic with `ping 8.8.8.8` |
| WireGuard tunnel down | Re-check `WG_PRIVATE_KEY` and `WG_VPS_PUBLIC_KEY` in `.env` — see [WIREGUARD_SETUP.md](WIREGUARD_SETUP.md) |
| Container restarting | `docker compose -f docker-compose.raspi.yml logs --tail=50 <service>` |
| Sensor not appearing in cloud dashboard | Verify WireGuard handshake; check `VPS_API_URL` and `API_KEY` in `.env` |
| Local dashboard blank | `docker logs idps-pi-dashboard --tail 20` |
| MongoDB connection refused | `docker exec idps-mongodb-pi mongosh --eval "db.adminCommand('ping')"` |
