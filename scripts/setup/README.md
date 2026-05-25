# NetSentry Sensor

Network Intrusion Detection & Prevention System (IDPS) sensor for home networks.

## System Requirements

### Hardware Minimum

| Resource | Build Time | Running (Production) |
|----------|------------|---------------------|
| **RAM** | ~16 GB | 4-8 GB |
| **Disk** | 20 GB free | 10 GB |
| **CPU** | 4+ cores | 2+ cores |

> **Note:** The initial build requires ~16GB RAM because Docker builds Suricata from source. Once built, the running containers use 4-8GB depending on traffic volume. Use prebuilt images to skip the build step.

### Supported Platforms

- **Linux** - Any modern Linux distribution (Debian, Ubuntu, etc.)
- **Architecture:** AMD64 (x86_64) or ARM64

## Quick Install

### Option A: Use Prebuilt Images (Recommended)

Prebuilt Docker images are automatically pulled from GitHub Container Registry. No local build required.

```bash
# One-line installer (uses prebuilt images by default)
curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup/install.sh | sudo bash
```

### Option B: Build Locally (Maximum Compatibility)

Build all images from source. Requires ~16GB RAM and takes 15-30 minutes.

```bash
# Set environment variable to force local build
export NETSENTRY_BUILD_LOCAL=true

# Then run installer
curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup/install.sh | sudo bash
```

Or manually:

```bash
git clone https://github.com/yourorg/netsentry-sensor.git /opt/netsentry
cd /opt/netsentry

# Edit .env with your configuration
cp .env.example .env
nano .env

# Build and start (for local build, run: docker compose build)
docker compose -f docker-compose.yml up -d
```

## Configuration

### Environment Variables

Create `/opt/netsentry/.env`:

```bash
# Required: VPS endpoint for data submission
VPS_ENDPOINT=https://idps.example.com

# WireGuard tunnel configuration
WG_ADDRESS=10.10.0.2/24
WG_PORT=51820
WG_KEEPALIVE=25
WG_PRIVATE_KEY=<your-wireguard-private-key>
```

### WireGuard Setup

Run the WireGuard setup script:

```bash
# For Linux sensor client
sudo ./setup-wireguard-pi.sh

# For VPS server
sudo ./setup-wireguard-vps.sh
```

See [SETUP-WIREGUARD.md](SETUP-WIREGUARD.md) for detailed platform-specific instructions.

## Usage

### Starting the Sensor

The installer automatically starts the sensor via systemd. If not:

```bash
# Manual start
cd /opt/netsentry
docker compose -f docker-compose.yml up -d

# Or use systemd
sudo systemctl start idps-bridge
```

### Stopping the Sensor

```bash
# Stop containers
cd /opt/netsentry
docker compose -f docker-compose.yml down

# Or use systemd
sudo systemctl stop idps-bridge
```

### Viewing Logs

```bash
# Docker logs
docker compose -f docker-compose.yml logs -f

# Systemd logs
sudo journalctl -u idps-bridge -f

# Specific container
docker logs -f netsentry-suricata
docker logs -f netsentry-api-gateway
```

### Checking Status

```bash
# Container status
docker compose -f docker-compose.yml ps

# WireGuard status
sudo wg show

# Systemd status
sudo systemctl status idps-bridge
```

## Maintenance

### Updating

```bash
# Pull latest images (prebuilt) or rebuild (local)
cd /opt/netsentry

# For prebuilt images
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d

# For local build
docker compose -f docker-compose.yml build --no-cache
docker compose -f docker-compose.yml up -d
```

### Updating the Installer

```bash
# Re-download and run installer
curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup/install.sh | sudo bash
```

### Logs Rotation

Docker logs are automatically handled. For journald logs:

```bash
# Keep last 7 days of logs
sudo journalctl -u idps-bridge --vacuum-time=7d

# Or limit log size
sudo journalctl -u idps-bridge --vacuum-size=100M
```

### Restarting Services

```bash
# Restart sensor
sudo systemctl restart idps-bridge

# Restart specific container
docker restart netsentry-suricata
```

### Uninstallation

```bash
# Stop and remove containers
cd /opt/netsentry
docker compose -f docker-compose.yml down

# Remove data volumes (optional)
docker compose -f docker-compose.yml down -v

# Remove installation directory
sudo rm -rf /opt/netsentry

# Remove systemd service
sudo rm /etc/systemd/system/idps-bridge.service
sudo systemctl daemon-reload
```

## Prebuilt Images vs Local Build

### When to Use Prebuilt Images

- Limited RAM (less than 16GB)
- Quick setup
- Production deployments
- ARM64 architecture

### When to Build Locally

- Need custom Suricata rules
- Maximum compatibility
- Development/customization
- Specific CPU architecture not in prebuilt images

### Prebuilt Image Registry

Images are hosted at:
- `ghcr.io/yourorg/netsentry-suricata`
- `ghcr.io/yourorg/netsentry-api-gateway`
- `ghcr.io/yourorg/netsentry-bridge`

## Troubleshooting

### Out of Memory During Build

```bash
# Use prebuilt images instead
export NETSENTRY_BUILD_LOCAL=false
# Then re-run installer
```

### Container Won't Start

```bash
# Check logs
docker logs netsentry-suricata

# Check configuration
cat /opt/netsentry/.env

# Verify WireGuard
sudo wg show
```

### No Data Reaching VPS

```bash
# Test connectivity
curl -sf https://idps.example.com/health

# Check WireGuard tunnel
ping -c 3 10.10.0.1

# Check firewall
sudo iptables -L -n
```

## Project Structure

```
netsentry-sensor/
├── docker-compose.yml       # Main compose file
├── scripts/
│   └── setup/
│       ├── install.sh            # One-line installer
│       ├── setup-bridge-unified.sh
│       └── idps-bridge.service
├── images/
│   ├── suricata/             # Suricata IDPS image
│   ├── api-gateway/          # API Gateway image
│   └── bridge/               # Network bridge image
├── setup-wireguard-*.sh      # WireGuard setup scripts
└── SETUP-WIREGUARD.md        # WireGuard documentation
```

## Support

- Issues: https://github.com/yourorg/netsentry-sensor/issues
- Discussions: https://github.com/yourorg/netsentry-sensor/discussions
