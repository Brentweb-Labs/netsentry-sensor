# NetSentry Sensor - Quick Setup Guide

## System Requirements

| Resource | Build (Local) | Running (Prebuilt) |
|----------|---------------|-------------------|
| **RAM** | ~8 GB | 2-4 GB |
| **Disk** | 10 GB | 5 GB |
| **CPU** | 4+ cores | 2+ cores |

## Quick Install (Recommended - Uses Prebuilt Binaries)

```bash
# Single command - everything automated
curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup.sh | sudo bash

# With VPS public key
curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup.sh | sudo bash -s <vps-public-key>
```

This takes **~2-5 minutes** using prebuilt binaries.

## Build from Source (Customization)

If you need to modify the Rust code:

```bash
# Clone and build
git clone https://github.com/yourorg/netsentry-sensor.git
cd netsentry-sensor

# Build locally (~30 minutes on first build)
make build-local
```

## Manual Docker Setup

```bash
# Pull prebuilt images
docker compose -f docker-compose.raspi.yml pull

# Or build locally
docker compose -f docker-compose.raspi.yml build

# Start
docker compose -f docker-compose.raspi.yml up -d
```

## Usage

### Start/Stop
```bash
# Using docker
cd /opt/netsentry
docker compose -f docker-compose.raspi.yml up -d
docker compose -f docker-compose.raspi.yml down

# Using systemd (if installed)
sudo systemctl start netsentry
sudo systemctl stop netsentry
```

### Logs
```bash
docker compose -f docker-compose.raspi.yml logs -f
journalctl -u netsentry -f
```

### Update
```bash
# Just pull latest binaries
docker compose -f docker-compose.raspi.yml pull
docker compose -f docker-compose.raspi.yml up -d

# Or rebuild completely
docker compose -f docker-compose.raspi.yml build --no-cache
docker compose -f docker-compose.raspi.yml up -d
```

## Prebuilt Binaries

Prebuilt binaries are automatically built and released via GitHub Actions on every push to main. They support:
- **AMD64** (x86_64)
- **ARM64** (aarch64 - Raspberry Pi 4/5)

Get the latest binaries from: https://github.com/yourorg/netsentry-sensor/releases
