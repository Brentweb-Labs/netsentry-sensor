# Setup Guide

## Prerequisites

- Docker 24+ and Docker Compose plugin on both hosts
- VPS (Ubuntu 22.04+) with public IP
- Raspberry Pi 4 with two ethernet interfaces
- WireGuard keys exchanged (see [PI_BRIDGE_SETUP.md](PI_BRIDGE_SETUP.md))

---

## VPS

```bash
cp .env.example .env             # fill passwords, API_KEY, WireGuard peer key
sudo sysctl -w vm.max_map_count=262144   # required for Elasticsearch (once per host)
docker compose -f docker-compose.vps.yml up -d
```

Verify:
```bash
docker compose -f docker-compose.vps.yml ps
curl https://idps.brentweb.eu/api/vps/health
```

> The Traefik reverse proxy stack must be running and the `proxy` Docker network must exist before starting the IDPS stack.

---

## Raspberry Pi

```bash
# One-time: set up network bridge
sudo ./scripts/setup/setup-bridge-unified.sh

cp .env.example .env   # set VPS_IP, WG_PRIVATE_KEY, WG_VPS_PUBLIC_KEY, SURICATA_IFACE
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
sudo ./scripts/idps-manager.sh deploy-vps    # start VPS services
sudo ./scripts/idps-manager.sh deploy-raspi  # start Pi services
sudo ./scripts/idps-manager.sh bridge-status # check br0
sudo ./scripts/idps-manager.sh fix-eve       # ensure eve.json exists
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| No events in `eve.json` | Run `fix-eve`, check `SURICATA_IFACE`, generate traffic with `ping 8.8.8.8` |
| WireGuard down | Re-check keys in `.env` — see [PI_BRIDGE_SETUP.md](PI_BRIDGE_SETUP.md) |
| Container restarting | `docker compose -f <file> logs --tail=50 <service>` |
| Elasticsearch won't start | `sudo sysctl -w vm.max_map_count=262144` |
