# SPAN Topology Deployment Guide

## Overview

The **SPAN (Switched Port Analyzer)** topology is an **out-of-band passive monitoring** configuration for NetSentry Sensor. Instead of sitting inline between your modem and network (which requires network bridge configuration), the edge device monitors a mirrored copy of network traffic from a managed switch.

### When to use SPAN vs. Inline Bridge

| Aspect | Inline Bridge | SPAN |
|---|---|---|
| **Setup complexity** | Complex (requires bridge, WireGuard pairing) | Simpler (just port mirroring) |
| **Failure mode** | Device failure = network down | Device failure = no alerts (traffic flows normally) |
| **Hardware requirement** | Device with 2+ network interfaces | Device with 1+ interface + managed switch with SPAN support |
| **Latency** | None (transparent bridge) | None (passive monitoring) |
| **Traffic loss** | 0% (guaranteed inline) | Possible if mirror port saturated |
| **Network reconfiguration** | Required (bridge setup) | None |
| **Best for** | Tight integration, fail-safe inline blocking | Existing networks, low-touch deployment |

---

## Architecture

```
┌─────────────┐
│    Modem    │
└──────┬──────┘
       │
       │ (from ISP)
       │
┌──────▼──────────────────────┐
│   Managed Switch             │
│  (with Port Mirroring/SPAN)  │
└──┬──────────┬──────────┬──────┬┘
   │          │          │      │
Source    Source     ...   Mirror
Port 1    Port 2          Port (N)
   │          │          │      │
Router      Wi-Fi       ...   Mirror→Pi
           AP                (Destination)
                               │
                        ┌──────▼────────┐
                        │  Edge Device  │
                        │ (capture IF)  │
                        │ (passive      │
                        │  monitoring)  │
                        └───────────────┘
```

**Key point:** The switch **mirrors** all traffic from selected source ports to the mirror destination port, where the Pi listens passively. The Pi receives a copy of all network traffic but is **not in the path** — it cannot disrupt traffic flow.

---

## Prerequisites

1. **Managed network switch** with port mirroring (SPAN) support:
   - Must support configuring SPAN/port mirroring via web UI or CLI
   - Must have at least 3 network ports (sources + 1 mirror destination)

2. **Edge device (Linux-based):**
   - Linux operating system (Ubuntu 22.04+, Debian, Alpine, etc.)
   - At least 4 GB RAM recommended for full sensor stack
   - One or more Ethernet network interfaces
   - Docker 24+ with Docker Compose plugin installed
   - Root or sudo access

3. **Network setup requirements:**
   - Edge device Ethernet interface connected to switch's mirror destination port
   - Switch configured to mirror traffic from monitored ports to mirror destination
   - Network path to reach your NetSentry management platform

4. **NetSentry management platform** (deployed separately):
   - Already running and accessible from edge device
   - WireGuard tunnel established between edge and management platform

---

## Setup Steps

### Step 1: Configure Switch Port Mirroring

Access your managed switch's web UI or CLI:

```
http://<switch_ip>   (typical defaults: 192.168.0.1, 192.168.1.1, etc.)
```

Navigate to the port mirroring or SPAN configuration section (location varies by switch model):

**Generic Configuration:**
- **Port Mirroring/SPAN:** Enable
- **Monitored Ports (source/ingress):** Select ports carrying traffic you want to monitor
  - Typically includes: router/uplink ports, Wi-Fi access point ports
  - May include: critical servers, backup locations, etc.
- **Monitoring Port (destination/egress):** Select the port where your Pi is connected
- **Click:** Save/Apply

**Where to find port mirroring:**
- Netgear: Administration → Port Mirroring
- TP-Link: Features → Port Mirroring
- D-Link: Advanced → Port Mirroring
- Ubiquiti: Settings → Port Mirroring
- Cisco/Arista: Monitor Sessions (CLI: `monitor session X source ...`)
- pfSense: Interfaces → Switches → Port Mirroring

**Verification script** (included):

```bash
sudo ./scripts/setup/setup-span-port.sh status
```

This checks:
- Switch is reachable on the network
- Pi's capture interface (`eth0`) is UP
- Network topology
- Current traffic stats on the interface

### Step 2: Prepare Environment

Copy the example environment file and configure:

```bash
cd /path/to/netsentry/sensor
cp .env.example .env
```

**Key variables for SPAN topology:**

```bash
# VPS connectivity (same as inline bridge)
VPS_ENDPOINT=http://10.10.0.1:8080
VPS_API_URL=https://idps.brentweb.eu/api/vps
PACKET_STREAM_WS_URL=wss://idps.brentweb.eu/ws/packets
API_KEY=<your-api-key>

# WireGuard (same as inline bridge)
WG_PRIVATE_KEY=<base64-encoded-pi-private-key>
WG_VPS_PUBLIC_KEY=<base64-encoded-vps-public-key>
VPS_PUBLIC_IP=<vps-public-ip>

# SPAN-specific: Capture interface (eth0 only)
SURICATA_IFACE=eth0
CAPTURE_INTERFACE=eth0

# Optional: Firewall integration
FIREWALL_API_URL=http://192.168.1.1
FIREWALL_API_KEY=<router-api-key>
```

> **Note:** Unlike inline bridge, there is **no network bridge** to configure — the Pi is passive and reads traffic from `eth0` only.

### Step 3: Start Services

```bash
# Inline raspberry pi services + SPAN-specific services
docker compose -f docker-compose.raspi.yml -f docker-compose.span.yml up -d
```

This starts:
- **Suricata** (monitors `eth0` for mirrored traffic)
- **packet-processor** (libpcap capture from `eth0`)
- **firewall-forwarder** (optional: forwards block commands to your router)
- Plus all other standard Pi services (WireGuard, raspi-collector, network-filter, etc.)

### Step 4: Verify Mirroring is Working

```bash
# Watch packet arrival on the capture interface
# Replace "eth0" with your actual interface from CAPTURE_INTERFACE in .env
watch -n1 'cat /sys/class/net/eth0/statistics/rx_packets'

# Capture 10 packets with tcpdump
# Replace "eth0" with your actual CAPTURE_INTERFACE
sudo tcpdump -i eth0 -c 10

# Check Suricata is seeing traffic (inside Docker container)
docker logs idps-suricata-pi | grep "eve.json"

# Or check raw logs directly (path depends on your deployment)
ls -lh ./data/logs/suricata/eve.json
```

If `rx_packets` is increasing and `eve.json` has entries, mirroring is working.

### Step 5: Verify VPS Connection

```bash
# Check WireGuard tunnel is active
docker exec idps-wireguard wg show wg0

# Check edge device can reach management platform over tunnel
docker exec idps-raspi-collector curl -v http://10.10.0.1:8080/health

# Verify in management platform dashboard
# Visit your management platform URL (e.g., https://your-netsentry-domain.com)
```

---

## Service Details (SPAN-specific)

### Suricata

- **Container name:** `idps-suricata-pi`
- **Interface:** Configured via `CAPTURE_INTERFACE` environment variable in `.env` (default: `eth0`)
- **Mode:** `autofp` (auto load-balancing across threads)
- **Rules:** Updated from management platform via `rule-engine` service
- **Output:** `eve.json` (JSON alerts logged to `./data/logs/suricata/`)
- **Memory limit:** 1 GB

### Packet-Processor

- **Container name:** `idps-packet-processor-pi`
- **Captures from:** Interface configured via `CAPTURE_INTERFACE` in `.env`
- **Sends to:** Management platform via WebSocket at `PACKET_STREAM_WS_URL`
- **Role:** Supplements Suricata alerts with raw packet data
- **Memory limit:** 256 MB

### Firewall-Forwarder

- **Container name:** `idps-firewall-forwarder`
- **Port:** 8092
- **Role:** Forwards blocking decisions from management platform to your network appliance (optional)
- **When used:** If your network device supports API-based blocking
- **Configuration (optional):**
  ```bash
  FIREWALL_API_URL=http://<your-firewall-or-router-ip>
  FIREWALL_API_KEY=<api-key-if-required>
  ```
- **If not using:** Leave `FIREWALL_API_URL` empty for monitoring-only mode
- **Memory limit:** 64 MB

---

## Docker Compose Override

The `docker-compose.span.yml` is meant to be **composed** with `docker-compose.raspi.yml`:

```bash
docker compose -f docker-compose.raspi.yml -f docker-compose.span.yml up -d
```

**What each file does:**

| File | Contents |
|---|---|
| `docker-compose.raspi.yml` | Base Pi services (WireGuard, raspi-collector, network-filter, MongoDB, Redis, etc.) |
| `docker-compose.span.yml` | SPAN-specific overrides: Suricata (monitors eth0), packet-processor (eth0), firewall-forwarder (block command relay) |

When both are specified, **docker-compose merges them** — services defined in `span.yml` override base `raspi.yml` equivalents.

---

## Blocking in SPAN Topology

### Option A: Via Firewall/Router API (Recommended)

If your network appliance (firewall, router, etc.) supports API-based blocking:

1. **Configure firewall API in `.env`:**
   ```bash
   FIREWALL_API_URL=http://<your-firewall-ip>:port
   FIREWALL_API_KEY=<your-firewall-api-key-if-required>
   ```

2. **Enable auto-blocking on management platform:**
   - Set `AUTO_BLOCK_ENABLED=true` in platform configuration
   - Verify the API endpoint matches your device's actual interface

3. **How it works:** Edge device's network-filter receives block commands from management platform, forwards to firewall-forwarder, which relays to your firewall/router

### Option B: Local Device-Level Blocking (Advanced)

The `network-filter` service can apply local rules. However, since the edge device is **not in the traffic path**, local blocking won't prevent client access to blocked IPs. Use only for:
- Logging/monitoring dropped packets
- Advanced network scenarios with special routing rules

### Option C: Monitoring-Only Mode (Default)

For SPAN topology focused purely on detection and alerting:
1. Leave `FIREWALL_API_URL` empty or unconfigured
2. Set `AUTO_BLOCK_ENABLED=false`
3. Handle blocking decisions manually based on management platform alerts

---

## Troubleshooting

### Edge device not receiving traffic

**Check mirroring is configured on your switch:**
1. Access switch management interface
2. Verify SPAN/port mirroring is enabled
3. Confirm source ports are correctly selected
4. Confirm mirror destination port matches your device's connection

**Verify on edge device:**

```bash
# Check interface is up (replace eth0 with your CAPTURE_INTERFACE)
ip link show eth0

# Watch for incoming packets
watch -n1 'cat /sys/class/net/eth0/statistics/rx_packets'

# Capture packets to verify traffic arrival
sudo tcpdump -i eth0 -c 5
```

**If packets aren't arriving:**
1. Verify switch SPAN configuration is enabled
2. Confirm cable connections (device to mirror destination port)
3. Confirm source ports have active traffic
4. Check device IP configuration (should have IP or be in promiscuous mode)

### Suricata container not starting

```bash
docker logs idps-suricata-pi --tail 30
```

**Common issues:**
- Capture interface (CAPTURE_INTERFACE in .env) doesn't exist
- Config file path is incorrect
- Rules directory has permission issues
- Insufficient memory (check `docker stats`)

**Reset:**
```bash
docker compose -f docker-compose.raspi.yml -f docker-compose.span.yml restart idps-suricata-pi
```

### Eve.json not receiving alerts

```bash
# Check if logs are being written
ls -lh ./data/logs/suricata/eve.json

# Watch for new entries
tail -f ./data/logs/suricata/eve.json | head -5
```

**If not growing:**
1. Verify traffic is arriving on capture interface:
   ```bash
   watch -n1 'cat /sys/class/net/eth0/statistics/rx_packets'
   ```
2. Check Suricata is running:
   ```bash
   docker ps | grep suricata
   ```
3. Review Suricata logs:
   ```bash
   docker logs idps-suricata-pi --tail 50 | grep -i error
   ```
4. Verify rules loaded:
   ```bash
   docker logs idps-suricata-pi 2>&1 | grep -i "rule\|loaded"
   ```

### Firewall-forwarder connection issues

```bash
docker logs idps-firewall-forwarder --tail 30
```

**If "connection refused" or timeout:**
1. Verify your firewall/router is reachable from edge device:
   ```bash
   ping <your-firewall-ip>
   ```
2. Check FIREWALL_API_URL and FIREWALL_API_KEY in `.env`:
   ```bash
   grep FIREWALL_ .env
   ```
3. Test firewall API endpoint manually:
   ```bash
   curl -v http://<your-firewall-ip>/api/status
   ```
4. Verify firewall supports the API endpoint you configured
5. If firewall doesn't have API support, this service is optional — leave disabled

### Blocks not reaching firewall

**Check the flow:**
1. VPS sends block command over WebSocket
2. raspi-collector receives and hands to network-filter
3. network-filter calls firewall-forwarder on `:8092`
4. firewall-forwarder calls router API

**Debug each step:**

```bash
# 1. Check network-filter received the command
docker logs idps-network-filter-pi | grep -i block

# 2. Check firewall-forwarder was called
docker logs idps-firewall-forwarder | grep -i block

# 3. Check router received the request
# (depends on router; check its logs/UI)
```

---

## Monitoring & Alerts

Once running, SPAN topology sends:

- **Suricata alerts** → raspi-collector → VPS (stored in MongoDB)
- **Raw packets** → packet-processor → VPS (optional packet stream)
- **Hardware metrics** → telemetry service → VPS (CPU, memory, disk, temperature)

Access alerts in the NetSentry dashboard at `https://idps.brentweb.eu`.

---

## Performance Considerations

### Packet Loss

If traffic volume is high (>100 Mbps sustained), the mirror port may saturate:

- **Monitor mirror port stats** on the switch web UI
- **Reduce scope:** Mirror only critical ports instead of all
- **Upgrade**: If bottleneck persists, consider an upgraded switch or inline bridge

### CPU/Memory on Pi

- **Suricata:** 512M reserved, 1G max
- **packet-processor:** 256M max
- **firewall-forwarder:** 64M max

Monitor with:

```bash
docker stats --no-stream
```

If memory is consistently near limit, enable swap or upgrade to Pi 8GB.

---

## Production Checklist

Before going live:

- [ ] Switch port mirroring configured and verified
- [ ] Pi eth0 is UP and receiving packets
- [ ] VPS endpoint is reachable (check WireGuard handshake)
- [ ] API key is set in `.env`
- [ ] WireGuard keys are configured
- [ ] MongoDB and Redis passwords changed (if exposed to untrusted network)
- [ ] Suricata rules are loading (check logs)
- [ ] Dashboard shows Pi as "Online"
- [ ] Test block command path (if using firewall-forwarder)
- [ ] Systemd service installed for auto-restart:
  ```bash
  sudo systemctl enable idps-bridge
  sudo systemctl start idps-bridge
  ```

---

## Migration from Inline Bridge to SPAN

If you're already running inline bridge and want to switch to SPAN:

1. **Stop inline bridge:**
   ```bash
   sudo systemctl stop idps-bridge
   ```

2. **Remove bridge:**
   ```bash
   sudo ./setup.sh bridge revert
   ```

3. **Reconfigure network:**
   - Disconnect Pi from eth0/eth1 roles
   - Connect Pi eth0 to switch mirror port
   - Set up DHCP or static IP on eth0

4. **Update `.env`:**
   - Keep: `VPS_ENDPOINT`, `WG_PRIVATE_KEY`, `WG_VPS_PUBLIC_KEY`, `API_KEY`
   - Set: `SURICATA_IFACE=eth0`, `CAPTURE_INTERFACE=eth0`
   - Add: `FIREWALL_API_URL` (if applicable)

5. **Start SPAN services:**
   ```bash
   docker compose -f docker-compose.raspi.yml -f docker-compose.span.yml up -d
   ```

---

## Reference

- **Port Mirroring script:** `scripts/setup/setup-span-port.sh`
- **Compose file:** `docker-compose.span.yml`
- **Related docs:** [ARCHITECTURE.md](ARCHITECTURE.md), [OPERATIONS.md](OPERATIONS.md)
