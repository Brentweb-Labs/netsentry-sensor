# =============================================================================
# NetSentry Dev/Test Simulation - README
# =============================================================================
# Production-grade Docker simulation using REAL NetSentry sensor implementations.
# This tests your actual Raspi collector, network-filter, rule-engine, etc.
# without requiring a physical Raspberry Pi.
#
# Cost: €0 | Hardware: Single Docker host | No physical Pi required
# =============================================================================

## Quick Start

```bash
# 1. Navigate to dev-test directory
cd dev-test

# 2. Copy environment file (optional - modify for cloud connection)
cp .env.example .env

# 3. Build and start all services
docker compose up --build -d

# 4. Wait for services (~60 seconds for first build)
docker compose ps

# 5. Run attack to generate alerts
docker compose exec attacker /attack-scripts/attack-nmap.sh

# 6. View alerts in real-time
docker compose logs -f suricata
```

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    docker-compose network (idps_net)                     │
│                         10.10.10.0/24                                    │
│                                                                          │
│  ┌────────────┐     ┌───────────┐     ┌───────────┐                     │
│  │ ATTACKER   │────▶│ SURICATA  │────▶│  VICTIM   │                     │
│  │ Kali       │     │  Sensor   │     │   DVWA    │                     │
│  │10.10.10.2  │     │10.10.10.3 │     │10.10.10.4 │                     │
│  └────────────┘     └───────────┘     └───────────┘                     │
│         │                                                                │
│         │                                                                 │
│  ┌──────┴───────────────────────────────────────────────────────────┐  │
│  │                   NETSENTRY EDGE SERVICES                         │  │
│  │                                                                    │  │
│  │  ┌────────────────┐   ┌────────────────┐   ┌────────────────┐    │  │
│  │  │ raspi-collector│   │network-filter  │   │  rule-engine   │    │  │
│  │  │  10.10.10.9    │   │   10.10.10.7   │   │   10.10.10.8   │    │  │
│  │  │ (your code!)   │   │  (your code!)  │   │  (your code!)  │    │  │
│  │  └────────────────┘   └────────────────┘   └────────────────┘    │  │
│  │                                                                    │  │
│  │  ┌────────────────┐   ┌────────────────┐                          │  │
│  │  │    mongodb     │   │     redis      │                          │  │
│  │  │   10.10.10.5   │   │   10.10.10.6   │                          │  │
│  │  └────────────────┘   └────────────────┘                          │  │
│  │                                                                    │  │
│  │  ┌────────────────┐                                                │  │
│  │  │   telemetry    │                                                │  │
│  │  │   10.10.10.10  │                                                │  │
│  │  └────────────────┘                                                │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

## Component Mapping

| Component | Container | IP | Your Code? | Purpose |
|-----------|-----------|-----|------------|---------|
| Attacker | `attacker` | 10.10.10.2 | No | Runs nmap, sqlmap, hydra |
| Victim | `victim` | 10.10.10.4 | No | Vulnerable DVWA web app |
| Sensor | `suricata` | 10.10.10.3 | No | IDPS engine (monitors traffic) |
| MongoDB | `idps-mongodb-dev` | 10.10.10.5 | No | Event storage |
| Redis | `idps-redis-dev` | 10.10.10.6 | No | Session cache |
| Network Filter | `idps-network-filter-dev` | 10.10.10.7 | **YES** | iptables DROP enforcement |
| Rule Engine | `idps-rule-engine-dev` | 10.10.10.8 | **YES** | Suricata rule management |
| Raspi Collector | `idps-raspi-collector-dev` | 10.10.10.9 | **YES** | eve.json tailer + cloud bridge |
| Telemetry | `idps-telemetry-dev` | 10.10.10.10 | **YES** | Hardware metrics |

## Testing Your Edge Services

### 1. Generate Traffic (triggers Suricata alerts)
```bash
# From attacker container
docker compose exec attacker /attack-scripts/attack-nmap.sh
docker compose exec attacker /attack-scripts/attack-sql.sh
```

### 2. Check Raspi Collector (your code)
```bash
# View logs from your collector
docker compose logs -f idps-raspi-collector-dev

# Check if it's reading eve.json
docker compose exec idps-raspi-collector-dev ls -la /var/log/suricata/
```

### 3. Check Network Filter (your code)
```bash
# View logs
docker compose logs -f idps-network-filter-dev

# Check if iptables rules were created
docker compose exec idps-network-filter-dev iptables -L -n
```

### 4. Check Rule Engine (your code)
```bash
# View logs
docker compose logs -f idps-rule-engine-dev

# Check if rules are loaded
docker compose exec suricata suricatasc -c "rule-list"
```

### 5. Verify Events in MongoDB
```bash
# Connect to MongoDB
docker compose exec idps-mongodb-dev mongosh -u admin -p DevPassword123! --authenticationDatabase admin idps_database

# Query events
db.events.find().limit(10).pretty()
```

## Cloud Integration

To connect to your real NetSentry Cloud:

1. Edit `.env` and set:
   ```
   VPS_ENDPOINT=https://idps.brentweb.eu
   VPS_WS_URL=wss://idps.brentweb.eu/ws
   API_KEY=your-real-api-key
   ```

2. The raspi-collector will:
   - Read `eve.json` from Suricata
   - POST events to your cloud API
   - Receive block/rule commands via WebSocket
   - Forward to network-filter and rule-engine

## Available Attack Scripts

### Nmap Aggressive Scan
```bash
docker compose exec attacker /attack-scripts/attack-nmap.sh
```
Triggers: ET SCAN, ET OS Intentional nmap, Port Scan rules

### SQL Injection
```bash
docker compose exec attacker /attack-scripts/attack-sql.sh
```
Triggers: ET WEB_ATTACK SQL INJECTION rules

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Build fails on Rust services | Ensure Docker has >2GB memory for builds |
| MongoDB connection errors | Wait for mongodb to be healthy: `docker compose ps` |
| No alerts in MongoDB | Check raspi-collector logs for eve.json parsing errors |
| network-filter not blocking | Verify API endpoint responds at http://10.10.10.7:8092 |
| rule-engine not reloading rules | Check suricata socket exists at /var/run/suricata/ |

## Cleanup

```bash
# Stop everything
docker compose down

# Stop and remove volumes (resets database)
docker compose down -v

# Full reset (including builds)
docker compose down --rmi local -v
```

## First-Time Build Note

The first `docker compose up --build` will compile all your Rust services:
- raspi-collector
- network-filter
- rule-engine
- telemetry

This may take 5-10 minutes depending on your machine. Subsequent builds are faster.
