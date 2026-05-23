# =============================================================================
# NetSentry Dev/Test Simulation - README
# =============================================================================
# Production-grade Docker simulation of enterprise network for IDPS testing.
# Mirrors your production Pi sensor topology.
#
# Cost: €0 | Hardware: Single Docker host | No physical switches
# =============================================================================

## Quick Start

```bash
# 1. Navigate to dev-test directory
cd dev-test

# 2. Start all containers
docker compose up -d

# 3. Wait for containers to be ready (~30 seconds)
docker compose ps

# 4. Enter attacker container
docker compose exec attacker /bin/bash

# 5. Run attack from inside attacker container
/attack-scripts/attack-nmap.sh

# 6. View alerts (from host)
cat data/logs/suricata/eve.json | jq '.alert'
```

## Network Topology

```
┌─────────────────────────────────────────────────────────────┐
│              docker-compose network (idps_net)              │
│                    10.10.10.0/24                            │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │   ATTACKER   │───▶│   SURICATA   │───▶│   VICTIM     │  │
│  │   Kali       │    │   Sensor     │    │   DVWA       │  │
│  │ 10.10.10.2   │    │  10.10.10.3  │    │  10.10.10.4  │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│         │                   │                   │           │
└─────────┴───────────────────┴───────────────────┴───────────┘
```

## Component Details

| Component | Container | Image | IP | Purpose |
|-----------|-----------|-------|-----|---------|
| Attacker | `attacker` | kali-rolling | 10.10.10.2 | Runs nmap, sqlmap, hydra |
| Sensor | `suricata` | jasonish/suricata:7.0.5 | 10.10.10.3 | IDPS engine (monitors traffic) |
| Victim | `victim` | citizenstig/dvwa | 10.10.10.4 | Vulnerable web app |

## Available Attack Scripts

### 1. Nmap Aggressive Scan
```bash
docker compose exec attacker /attack-scripts/attack-nmap.sh
```
Triggers: ET SCAN, ET OS Intentional nmap, Port Scan rules

### 2. SQL Injection
```bash
docker compose exec attacker /attack-scripts/attack-sql.sh
```
Triggers: ET WEB_ATTACK SQL INJECTION rules

## Viewing Alerts

### Option 1: Tail eve.json directly
```bash
docker compose exec suricata tail -f /var/log/suricata/eve.json
```

### Option 2: Use view-logs script
```bash
./scripts/view-logs.sh              # Live streaming
./scripts/view-logs.sh --alerts     # Only alerts
./scripts/view-logs.sh --count=20   # Last 20 events
```

### Option 3: Docker volume mount
The logs are also available at `./data/logs/suricata/` on the host.

## Cloud Integration (your NetSentry Cloud)

Your cloud management platform can ingest alerts by:

1. **File-based**: Mount `./data/logs/suricata` to your cloud container and tail eve.json
2. **Webhook**: Modify the script to POST alerts to your API endpoint
3. **MongoDB**: Stream to your existing MongoDB (see docker-compose.raspi.yml)

## Security Isolation

- **No exposed ports**: All containers isolated to internal Docker network
- **Non-root users**: Victim runs as www-data
- **Privileged Suricata**: Only for packet capture (dev/test only)
- **Internal DNS**: 8.8.8.8, 1.1.1.1 for resolution

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Containers won't start | Check Docker Desktop is running |
| Suricata not logging | Check `tail /var/log/suricata/suricata.log` |
| No alerts generated | Run attack script inside attacker container |
| eve.json empty | Ensure traffic flows through correct interface |

## Cleanup

```bash
docker compose down        # Stop containers
docker compose down -v    # Stop and remove volumes
```

## Production Notes

This configuration is for **dev/test only**. For production deployment,
see the parent directory's `docker-compose.raspi.yml` which includes:
- WireGuard VPN tunnel to cloud
- Physical network bridge (br0)
- Edge services (raspi-collector, network-filter, rule-engine)
- MongoDB integration for event storage
