# WireGuard Setup Scripts

Set up WireGuard VPN between your Raspberry Pi and VPS.

## Quick Start

### Linux (Raspberry Pi)

```bash
# Step 1: Generate keys
sudo ./setup-wireguard-pi.sh

# Step 2: Copy the Pi public key to VPS, then run with VPS key
sudo ./setup-wireguard-pi.sh <vps-public-key>
```

### Linux (VPS)

```bash
# Step 1: Generate keys
sudo ./setup-wireguard-vps.sh

# Step 2: Copy the VPS public key to Pi, then run with Pi key
sudo ./setup-wireguard-vps.sh <pi-public-key>
```

### macOS

**Prerequisites:**
- Install Homebrew: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- Or download WireGuard: https://www.wireguard.com/install/

**Setup:**

```bash
# Step 1: Generate keys (as your user, no sudo needed)
./setup-wireguard-pi.command

# Step 2: Run with sudo to activate
sudo ./setup-wireguard-pi.command <vps-public-key>
```

For the VPS side on macOS:

```bash
# Step 1: Generate keys
./setup-wireguard-vps.command

# Step 2: Activate with sudo
sudo ./setup-wireguard-vps.command <pi-public-key>
```

### Windows

**Prerequisites:**
- Install WireGuard: https://www.wireguard.com/install/
- Or run: `winget install WireGuard.WireGuard`

**Setup (run PowerShell as Administrator):**

```powershell
# Step 1: Generate keys
.\setup-wireguard-pi.ps1

# Step 2: Run with VPS public key
.\setup-wireguard-pi.ps1 -VpsPublicKey "<key>"
```

## File Overview

| File | Platform | Description |
|------|----------|-------------|
| `setup-wireguard-pi.sh` | Linux | Pi client |
| `setup-wireguard-vps.sh` | Linux | VPS server |
| `setup-wireguard-pi.command` | macOS | Pi client |
| `setup-wireguard-vps.command` | macOS | VPS server |
| `setup-wireguard-pi.ps1` | Windows | Pi client |
| `setup-wireguard-vps.ps1` | Windows | VPS server |

## Configuration

Default network settings:
- **Pi tunnel IP:** 10.10.0.2/24
- **VPS tunnel IP:** 10.10.0.1/24
- **WireGuard port:** 51820/udp
- **VPS public IP:** 178.104.6.176 (set via `VPS_PUBLIC_IP` env var)

## Troubleshooting

### Key Exchange
1. Run Pi script first → copy the **Pi public key**
2. Run VPS script → copy the **VPS public key**  
3. Run both scripts again with the other's public key

### macOS "Running Homebrew as root" error
Don't run with sudo for the first step. The script installs Homebrew packages as your user, then uses sudo only for system config.

### Windows WireGuard not found
Install WireGuard from https://www.wireguard.com/install/ or run: `winget install WireGuard.WireGuard`

### Tunnel not connecting
1. Check both public keys are correct
2. Verify VPS firewall allows UDP port 51820
3. Check `wg show` on both sides
