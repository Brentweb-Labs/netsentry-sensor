# Setup Guide

## Prerequisites

- Raspberry Pi 4 (arm64) with two Ethernet interfaces (`eth0` — WAN, `eth1` — LAN)
- Docker 24+ with the Compose plugin
- A running NetSentry Cloud VPS instance (see [netsentry-cloud](https://github.com/yourorg/netsentry-cloud))
- WireGuard keys exchanged (the installer handles this automatically, or see [PI_BRIDGE_SETUP.md](PI_BRIDGE_SETUP.md))

---

## VPS (netsentry-cloud)

```bash
cp .env.example .env   # fill MONGO_ROOT_PASSWORD, API_KEY, STRIPE_*, SMTP_*, TWILIO_*
docker compose -f docker-compose.vps.yml up -d
```

Verify:
```bash
docker compose -f docker-compose.vps.yml ps
curl https://<your-domain>/health
```

> The Traefik reverse proxy stack must be running and the `proxy` Docker network must exist before starting the cloud stack.

---

## Raspberry Pi sensor

### Option A — One-line installer (recommended)

Run on the Pi as root:

```bash
curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup/install.sh | sudo bash
```

The installer will:
1. Install Docker, `wireguard-tools`, and `iptables-persistent`
2. Download all required files to `/opt/netsentry/`
3. Prompt for your `VPS_ENDPOINT` (e.g. `https://idps.example.com`)
4. Generate a WireGuard keypair — **copy the printed public key** and add it as a peer on the VPS:
   ```bash
   sudo wg set wg0 peer <PRINTED_PUBKEY> allowed-ips 10.10.0.2/32 persistent-keepalive 25
   sudo wg-quick save wg0
   ```
5. Install and start the `idps-bridge` systemd service

Manage afterwards:
```bash
systemctl status idps-bridge
journalctl -u idps-bridge -f
cd /opt/netsentry && docker compose -f docker-compose.raspi.yml up -d
```

### Option B — Manual setup

```bash
# One-time: set up the network bridge (eth0 ↔ eth1)
sudo ./scripts/setup/setup-bridge-unified.sh

# Configure environment
cp .env.example .env
# Required vars: VPS_ENDPOINT, API_KEY, WG_PRIVATE_KEY, WG_VPS_PUBLIC_KEY

# Start edge stack
docker compose -f docker-compose.raspi.yml up -d
```

Verify:
```bash
docker compose -f docker-compose.raspi.yml ps
docker logs idps-wireguard --tail 20
tail -f data/logs/suricata/eve.json
```

---

## Common commands

```bash
sudo ./scripts/idps-manager.sh status        # health snapshot
sudo ./scripts/idps-manager.sh deploy-raspi  # start Pi services
sudo ./scripts/idps-manager.sh bridge-status # check br0
sudo ./scripts/idps-manager.sh fix-eve       # ensure eve.json exists
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| No events in `eve.json` | Run `fix-eve`, check `SURICATA_IFACE`, generate traffic with `ping 8.8.8.8` |
| WireGuard tunnel down | Re-check keys in `.env` — see [PI_BRIDGE_SETUP.md](PI_BRIDGE_SETUP.md) |
| Container restarting | `docker compose -f docker-compose.raspi.yml logs --tail=50 <service>` |
| Pi dashboard blank | `docker logs idps-pi-dashboard --tail 20` |
