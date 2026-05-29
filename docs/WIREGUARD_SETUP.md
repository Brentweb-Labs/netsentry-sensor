# WireGuard Tunnel Setup Guide

## Overview

NetSentry Sensor uses **WireGuard** to create an encrypted tunnel between the edge device (sensor) and the management platform (cloud). This tunnel enables secure communication for:

- Threat alerts and security events (Pi → VPS)
- Block commands and rule updates (VPS → Pi)
- Telemetry and heartbeat monitoring (Pi → VPS)

### Tunnel Topology

```
Pi (10.10.0.2)  ←─────────── WireGuard ───────────→  VPS (10.10.0.1)
                              UDP/51820
                              (encrypted)
                     Internet (0.0.0.0/0)
```

| Component | Role | Address | Port |
|---|---|---|---|
| Pi (client) | Initiates tunnel | 10.10.0.2/24 | N/A (client) |
| VPS (server) | Listens for tunnel | 10.10.0.1/24 | 51820/UDP |
| Internet | Transport layer | VPS public IP | 51820/UDP |

---

## Prerequisites

### On Management Platform (Server)

- Linux server (Ubuntu 22.04+, Debian, CentOS, Fedora, Alpine, etc.)
- Root or sudo access
- Internet connectivity with port 51820/UDP open inbound
- Public or static IP address reachable from edge device

### On Edge Device (Client)

- Linux operating system (Ubuntu 22.04+, Debian, Alpine, Raspberry Pi OS, etc.)
- Network connectivity to management platform public IP
- Root or sudo access
- Management platform's public IP address known in advance

---

## Setup Methods

NetSentry Sensor supports two ways to set up WireGuard:

1. **Native Setup** (standalone Linux services)
   - Use bash scripts: `setup-wireguard-vps.sh` and `setup-wireguard-pi.sh`
   - Best for: Production deployments, systemd integration
   - Requires: WireGuard tools installed on host OS

2. **Docker Setup** (containerized tunnel)
   - Configured in `docker-compose.raspi.yml`
   - Best for: Quick deployment, isolated environment
   - Requires: Docker and Docker Compose

This guide covers both approaches.

---

## Method 1: Native Setup (Recommended)

### Step 1: Management Platform — Generate Keys and Initial Config

SSH into your management platform server and run:

```bash
# Navigate to sensor deployment directory
cd /path/to/netsentry-sensor

# Run WireGuard setup script (generates keys)
sudo ./setup.sh wireguard-cloud
```

**Output:**
```
[INFO] Installing WireGuard...
[INFO] Generating VPS key pair...
[INFO] VPS public key: <base64-vps-public-key>

[WARN] Run again with the Pi's public key to finish setup:
  ./setup-wireguard-vps.sh <pi-public-key>
```

**Save the VPS public key** — you'll give this to the Pi setup.

### Step 2: Edge Device — Generate Keys and Initial Config

SSH into your edge device and run:

```bash
# Navigate to sensor deployment directory
cd /path/to/netsentry-sensor

# Set management platform public IP (if different from default)
export VPS_PUBLIC_IP="<your-management-platform-public-ip>"

# Run WireGuard setup script (generates keys)
sudo ./setup.sh wireguard
```

**Output:**
```
[INFO] Installing WireGuard...
[INFO] Generating Pi key pair...
[INFO] Pi public key: <base64-pi-public-key>

[WARN] Run again with the VPS's public key to finish setup:
  ./setup-wireguard-pi.sh <vps-public-key>
```

**Save the Pi public key** — you'll give this to the VPS setup.

### Step 3: Management Platform — Configure with Edge Device's Public Key

Back on your management platform server, run the setup script again with the edge device's public key:

```bash
sudo ./setup-wireguard-vps.sh "<pi-public-key>"
```

**Output:**
```
[INFO] Writing WireGuard server config...
[INFO] Opening WireGuard port 51820/udp...
[INFO] Enabling and starting WireGuard...
[INFO] WireGuard VPS status:
interface: wg0
  public key: <vps-public-key>
  private key: (hidden)
  listening port: 51820

peer: <pi-public-key>
  endpoint: (not yet connected)
  allowed ips: 10.10.0.2/32
  latest handshake: (none)
  persistent keepalive: 25 seconds

[INFO] VPS tunnel IP: 10.10.0.1
[INFO] Pi tunnel IP:  10.10.0.2

[INFO] Update your VPS .env:
  RASPI_ENDPOINT=http://10.10.0.2:8080
```

**Update your VPS `.env` file:**
```bash
RASPI_ENDPOINT=http://10.10.0.2:8080
```

### Step 4: Edge Device — Configure with Management Platform's Public Key

Back on your edge device, run the setup script again with the management platform's public key:

```bash
sudo ./setup-wireguard-pi.sh "<vps-public-key>"
```

**Output:**
```
[INFO] Writing WireGuard client config...
[INFO] Enabling and starting WireGuard...
[INFO] Testing tunnel to VPS...
[INFO] Tunnel working — VPS reachable at 10.10.0.1

[INFO] WireGuard Pi status:
interface: wg0
  public key: <pi-public-key>
  private key: (hidden)
  address: 10.10.0.2/24

peer: <vps-public-key>
  endpoint: <vps-public-ip>:51820
  allowed ips: 10.10.0.1/32
  latest handshake: 2 seconds ago
  persistent keepalive: 25 seconds

[INFO] Pi tunnel IP:  10.10.0.2
[INFO] VPS tunnel IP: 10.10.0.1

[INFO] Update your Pi .env:
  VPS_ENDPOINT=http://10.10.0.1:8080
  VPS_WS_URL=ws://10.10.0.1:8080/ws/raspi
```

**Update your Pi `.env` file:**
```bash
VPS_ENDPOINT=http://10.10.0.1:8080
VPS_WS_URL=ws://10.10.0.1:8080/ws/raspi
```

### Step 5: Verify Tunnel Connectivity

From the **edge device**, test the tunnel:

```bash
# Ping the management platform over the tunnel
ping -c 3 10.10.0.1

# Check tunnel stats
sudo wg show wg0

# Look for "latest handshake: <N> seconds ago" — should be recent (< 2 minutes)
```

From the **management platform**, test the reverse:

```bash
# Ping the edge device over the tunnel
ping -c 3 10.10.0.2

# Check tunnel stats and look for recent handshake
sudo wg show wg0
```

**Successful tunnel:** Both sides show a recent "latest handshake" timestamp (within last 2 minutes).

---

## Method 2: Docker Setup

For containerized deployment, WireGuard is handled by the `idps-wireguard` service in `docker-compose.raspi.yml`.

### Prerequisites

You need to run the native setup **once** to generate keys, then use those keys in Docker environment variables.

### Step 1: Generate Keys (One-time, on any Linux machine)

```bash
# Generate a keypair
wg genkey | tee pi-private.key | wg pubkey > pi-public.key
wg genkey | tee vps-private.key | wg pubkey > vps-public.key

# Display keys for sharing
cat pi-public.key
cat vps-public.key
```

Or use the native scripts above to generate them.

### Step 2: Configure Environment Variables

Create or update `.env` with WireGuard variables:

```bash
# Pi side (.env on Pi)
WG_PRIVATE_KEY="<pi-private-key-base64>"
WG_VPS_PUBLIC_KEY="<vps-public-key-base64>"
VPS_PUBLIC_IP="<your-vps-public-ip>"
WG_ADDRESS="10.10.0.2/24"

# VPS side (.env on VPS, if using Docker there too)
WG_PRIVATE_KEY="<vps-private-key-base64>"
```

### Step 3: Start Docker Service

#### On Pi:

```bash
docker compose -f docker-compose.raspi.yml up -d wireguard
```

Check logs:

```bash
docker logs idps-wireguard -f
```

#### On VPS:

If your VPS also uses Docker, configure similarly. Otherwise, use the native setup above.

### Step 4: Verify Docker Tunnel

```bash
# Check if interface is up
docker exec idps-wireguard ip addr show wg0

# Ping VPS from Pi (inside container)
docker exec idps-wireguard ping -c 3 10.10.0.1

# Check WireGuard status
docker exec idps-wireguard wg show wg0
```

---

## Environment Variables Reference

### Edge Device (client-side) — `.env`

| Variable | Default | Description | Required |
|---|---|---|---|
| `WG_PRIVATE_KEY` | — | Base64-encoded edge device private key | Yes |
| `WG_VPS_PUBLIC_KEY` | — | Base64-encoded management platform public key | Yes |
| `VPS_PUBLIC_IP` | `178.104.6.176` | Management platform public IP address | Yes (update if different) |
| `WG_ADDRESS` | `10.10.0.2/24` | Edge device tunnel IP address | No |
| `WG_ALLOWED_IPS` | `10.10.0.1/32` | Management platform tunnel IP | No |
| `WG_KEEPALIVE` | `25` | Keepalive interval (seconds) | No |
| `VPS_ENDPOINT` | `http://10.10.0.1:8080` | Management platform API endpoint over tunnel | Yes |
| `VPS_API_URL` | — | Management platform public API endpoint (HTTPS) | Yes |

### Management Platform (server-side) — Config

| Variable | Default | Description |
|---|---|---|
| `WG_PORT` | `51820` | UDP port for incoming tunnel connections |
| `VPS_TUNNEL_IP` | `10.10.0.1/24` | Management platform tunnel IP address |
| `PI_TUNNEL_IP` | `10.10.0.2/32` | Edge device tunnel IP (in AllowedIPs) |

---

## Configuration Files

### Native Setup Config Locations

**VPS:**
```
/etc/wireguard/wg0.conf    — WireGuard interface config
/etc/wireguard/privatekey  — VPS private key (sensitive!)
/etc/wireguard/publickey   — VPS public key
```

**Pi:**
```
/etc/wireguard/wg0.conf    — WireGuard interface config
/etc/wireguard/privatekey  — Pi private key (sensitive!)
/etc/wireguard/publickey   — Pi public key
```

### Docker Config

WireGuard config is dynamically generated from environment variables via the entrypoint script:
```
raspi/wireguard/entrypoint.sh  — Generates /etc/wireguard/wg0.conf at startup
```

---

## Troubleshooting

### Tunnel Not Connecting

**Check on edge device:**

```bash
# 1. Is WireGuard service running?
sudo systemctl status wg-quick@wg0
# Or if using Docker:
docker exec idps-wireguard wg show wg0

# 2. Can you reach the management platform public IP?
ping -c 2 <management-platform-public-ip>

# 3. Are UDP packets reaching the tunnel port?
sudo ss -unl | grep 51820
```

**Check on management platform:**

```bash
# 1. Is WireGuard listening on port 51820?
sudo netstat -tlnup | grep 51820
# Or with newer tools:
sudo ss -unl | grep 51820

# 2. Verify firewall allows incoming UDP/51820
sudo ufw status | grep 51820
sudo iptables -L INPUT -n | grep 51820

# 3. Check WireGuard status and peer connection
sudo wg show wg0
# Should show: latest handshake: <N> seconds ago (recent)
```

**Common issues:**

- **"Endpoint unreachable"** — Edge device cannot reach management platform IP. Verify VPS_PUBLIC_IP in .env matches actual public IP.
- **"Port already in use"** — Another service is using 51820. Change WG_PORT or kill conflicting service.
- **"Permission denied"** — Run setup scripts with `sudo`.
- **"No route to host"** — Firewall blocking incoming UDP/51820 on management platform. Open it:
  ```bash
  sudo ufw allow 51820/udp
  # or
  sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT
  sudo netfilter-persistent save
  ```

### Tunnel Connected But APIs Not Reachable

```bash
# Test tunnel connectivity
ping -c 2 10.10.0.1        # From edge device

# Test API endpoint over tunnel
curl -v http://10.10.0.1:8080/health   # From edge device

# If API is in Docker, ensure it's listening on all interfaces
docker exec <api-container-name> netstat -tlnup | grep 8080

# Verify API configuration listens on correct interface (0.0.0.0 or specific IP)
# Check logs if API is in Docker
docker logs <api-container-name> | grep -i "listen\|port"
```

### Docker Container Won't Start

```bash
# Check logs
docker logs idps-wireguard

# Common error: "WG_PRIVATE_KEY is required"
# → Update .env with WG_PRIVATE_KEY value
# → Restart: docker compose up -d --force-recreate wireguard

# Error: "wireguard module not available"
# → On Pi, WireGuard kernel module may not be compiled
# → Use host networking mode in compose file:
#   network_mode: host
```

### Keepalive Issues

If the tunnel frequently disconnects:

1. Increase keepalive interval:
   ```bash
   # In /etc/wireguard/wg0.conf, increase PersistentKeepalive:
   PersistentKeepalive = 60  # default 25 seconds
   ```

2. Restart WireGuard:
   ```bash
   sudo wg-quick down wg0 && sudo wg-quick up wg0
   ```

---

## Key Rotation (Updating Keys)

If you need to rotate WireGuard keys (security best practice every 6 months):

### Step 1: Generate New Keys on Both Sides

```bash
# On both Pi and VPS
wg genkey | tee new-private.key | wg pubkey > new-public.key
```

### Step 2: Update VPS Configuration

```bash
# On VPS, stop the tunnel
sudo wg-quick down wg0

# Backup old config
sudo cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak

# Update with new keys and run setup script again
sudo ./setup-wireguard-vps.sh "<new-pi-public-key>"
```

### Step 3: Update Pi Configuration

```bash
# On Pi, update .env or config
# Set WG_PRIVATE_KEY to new Pi private key

# Restart WireGuard
sudo wg-quick down wg0 && sudo wg-quick up wg0

# Or if using Docker:
docker compose up -d --force-recreate wireguard
```

### Step 4: Verify New Keys Are Active

```bash
# Check the "public key" in output matches new one
sudo wg show wg0

# Test connectivity
ping -c 2 10.10.0.1
```

---

## Network Diagram

```
┌─────────────────────────────────────────────────────┐
│                    Internet                          │
│        (Open UDP/51820 on VPS public IP)            │
└────────────────┬──────────────────────┬─────────────┘
                 │                      │
            ┌────▼─────┐            ┌──▼──────┐
            │ VPS       │            │ Pi      │
            │ IP: X.X.X │            │ LAN: 192.168 │
            └────┬─────┘            └──┬──────┘
                 │                     │
         ┌───────▼──────────────────────▼──────┐
         │     WireGuard Tunnel (encrypted)    │
         │  10.10.0.1/24 ←→ 10.10.0.2/24      │
         │  UDP/51820 (Internet transport)     │
         └───────┬──────────────────────┬──────┘
                 │                      │
         ┌───────▼─────┐       ┌────────▼──┐
         │ API Server  │       │ Suricata  │
         │ raspi-      │       │ raspi-    │
         │ collector   │       │ collector │
         └─────────────┘       └───────────┘
              (VPS)                (Pi)
```

---

## Best Practices

1. **Protect Private Keys**
   - Store `WG_PRIVATE_KEY` in `.env` (gitignored)
   - Never commit keys to version control
   - Restrict file permissions: `chmod 600 /etc/wireguard/wg0.conf`

2. **Monitor Tunnel Health**
   ```bash
   # Periodic health check
   while true; do
     ping -c 1 -W 2 10.10.0.1 >/dev/null 2>&1 || alert "Tunnel down"
     sleep 300
   done
   ```

3. **Set Up Firewall Rules**
   ```bash
   # On VPS, restrict WireGuard port to known Pi IP if possible
   sudo ufw allow from <pi-public-ip> to any port 51820
   ```

4. **Use Strong, Unique Keypairs**
   - Don't reuse keypairs across environments
   - Rotate keys every 6 months

5. **Test Before Production**
   - Verify tunnel is stable for 24 hours
   - Check latest handshake is always recent (`< 2 min`)
   - Monitor for packet loss: `watch -n1 'wg show wg0'`

---

## Script Reference

### Management Platform Script: `setup-wireguard-vps.sh`

Run with: `./setup.sh wireguard-cloud`

```bash
# First run (generates keys, prints server public key)
sudo ./setup.sh wireguard-cloud

# Second run (configures with edge device's public key)
sudo ./setup.sh wireguard-cloud "<edge-device-public-key>"

# Help
./setup.sh wireguard-cloud --help
```

**What it does:**
1. Auto-detects Linux distribution (Ubuntu, Debian, CentOS, Alpine, etc.)
2. Installs `wireguard` and `wireguard-tools`
3. Generates server keypair at `/etc/wireguard/`
4. Writes WireGuard config to `/etc/wireguard/wg0.conf`
5. Opens firewall port 51820/UDP (if firewall is active)
6. Enables and starts `wg-quick@wg0` systemd service
7. Displays tunnel status and configuration

### Edge Device Script: `setup-wireguard-pi.sh`

Run with: `./setup.sh wireguard`

```bash
# First run (generates keys, prints edge device public key)
sudo ./setup.sh wireguard

# Second run (configures with management platform's public key)
sudo ./setup.sh wireguard "<management-platform-public-key>"

# Custom management platform IP
VPS_PUBLIC_IP="<your-ip>" sudo ./setup.sh wireguard

# Help
./setup.sh wireguard --help
```

**What it does:**
1. Auto-detects Linux distribution (Ubuntu, Debian, CentOS, Alpine, Raspberry Pi OS, etc.)
2. Installs `wireguard` and `wireguard-tools`
3. Generates client keypair at `/etc/wireguard/`
4. Writes WireGuard config to `/etc/wireguard/wg0.conf`
5. Enables and starts `wg-quick@wg0` systemd service
6. Tests tunnel connectivity with `ping 10.10.0.1`
7. Displays tunnel status and configuration

---

## Related Documentation

- [SETUP.md](SETUP.md) — Full deployment guide (mentions WireGuard pairing)
- [OPERATIONS.md](OPERATIONS.md) — WireGuard key rotation procedures
- [PI_BRIDGE_SETUP.md](PI_BRIDGE_SETUP.md) — Network bridge + WireGuard integration

