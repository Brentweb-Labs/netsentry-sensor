#!/bin/bash
# WireGuard Pi Client Setup for macOS
# Tunnel: Pi 10.10.0.2 <-> VPS 10.10.0.1
#
# Usage:
#   1. First run:  ./setup-wireguard-pi.command
#      (outputs Pi public key to share with VPS)
#   2. Second run: sudo ./setup-wireguard-pi.command <vps-public-key>
#
# Requirements:
#   - Homebrew: https://brew.sh
#   - WireGuard: https://www.wireguard.com/install/

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

WG_IFACE="utun"
PI_TUNNEL_IP="10.10.0.2/24"
VPS_TUNNEL_IP="10.10.0.1/32"
VPS_PORT="51820"
VPS_PUBLIC_IP="${VPS_PUBLIC_IP:-178.104.6.176}"

# Config location (no root needed for generation)
WG_DIR="$HOME/Library/Application Support/WireGuard"
mkdir -p "$WG_DIR"

USAGE="
===========================================
WireGuard Pi Client Setup for macOS
===========================================

First run (as your user):
  ./setup-wireguard-pi.command

This outputs your Pi public key. Share it with the VPS admin.

Second run (with sudo):
  sudo ./setup-wireguard-pi.command <vps-public-key>

Example:
  sudo ./setup-wireguard-pi.command ABCDEF12345...
"

show_help() {
    echo "$USAGE"
}

install_wireguard() {
    log "Checking WireGuard installation..."

    if command -v wg >/dev/null 2>&1; then
        log "WireGuard tools already installed"
        return 0
    fi

    if ! command -v brew >/dev/null 2>&1; then
        echo ""
        echo "Homebrew not found. Install it first:"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        echo ""
        echo "Or download WireGuard directly from:"
        echo "  https://www.wireguard.com/install/"
        error "Homebrew required for automated install"
    fi

    log "Installing WireGuard via Homebrew (as your user)..."
    brew install wireguard-tools
}

generate_keys() {
    log "Generating Pi key pair..."

    local privatekey_file="$WG_DIR/privatekey"
    local publickey_file="$WG_DIR/publickey"

    if [[ -f "$privatekey_file" && -f "$publickey_file" ]]; then
        warn "Keys already exist, skipping generation"
    else
        wg genkey | tee "$privatekey_file" | wg pubkey > "$publickey_file"
        chmod 600 "$privatekey_file"
    fi

    PI_PRIVATE_KEY=$(cat "$privatekey_file")
    PI_PUBLIC_KEY=$(cat "$publickey_file")
    log "Pi public key generated: $PI_PUBLIC_KEY"
}

write_config() {
    local vps_pubkey="$1"
    [[ -z "$vps_pubkey" ]] && error "Usage: sudo $0 <vps-public-key>"

    log "Writing WireGuard client config..."
    local conf_file="$WG_DIR/wg0.conf"

    cat > "$conf_file" << EOF
[Interface]
Address = $PI_TUNNEL_IP
PrivateKey = $PI_PRIVATE_KEY

# VPS server
[Peer]
PublicKey = $vps_pubkey
Endpoint = $VPS_PUBLIC_IP:$VPS_PORT
AllowedIPs = $VPS_TUNNEL_IP
PersistentKeepalive = 25
EOF
    chmod 600 "$conf_file"
    log "Config written to: $conf_file"
}

install_config() {
    log "Installing config to system location..."

    # System-wide config location
    local system_wg_dir="/etc/wireguard"
    local system_conf="$system_wg_dir/wg0.conf"

    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root - config stays in user directory"
        log "To activate the tunnel, either:"
        echo "  1. Use the WireGuard app: Menu Bar icon → Import tunnel from file"
        echo "  2. Or run: sudo ./setup-wireguard-pi.command $1"
        return 0
    fi

    # Root can install system-wide
    mkdir -p "$system_wg_dir"
    chmod 700 "$system_wg_dir"

    cp "$WG_DIR/wg0.conf" "$system_conf"
    chmod 600 "$system_conf"

    # Bring up tunnel
    log "Activating WireGuard tunnel..."
    if command -v wg-quick >/dev/null 2>&1; then
        wg-quick up "$system_conf" 2>/dev/null || warn "Could not bring up tunnel"
    fi
}

show_status() {
    echo ""
    echo "==========================================="
    log "Setup Complete!"
    echo "==========================================="
    echo ""
    echo "Tunnel Configuration:"
    echo "  Pi tunnel IP:   10.10.0.2"
    echo "  VPS tunnel IP:  10.10.0.1"
    echo "  VPS public IP:  $VPS_PUBLIC_IP"
    echo ""

    if [[ $EUID -eq 0 ]]; then
        echo "Tunnel Status:"
        wg show 2>/dev/null || warn "Interface not yet active"
    else
        echo "Next Steps:"
        echo "  1. Open WireGuard app (menu bar)"
        echo "  2. Import tunnel from: $WG_DIR/wg0.conf"
        echo "  3. Click Connect"
    fi

    echo ""
    echo "Update your Pi .env:"
    echo "  VPS_API_URL=http://10.10.0.1:8080"
    echo "  VPS_WS_URL=ws://10.10.0.1:8080/ws/raspi"
}

main() {
    local vps_pubkey="${1:-}"

    # Check if help requested
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        show_help
        exit 0
    fi

    echo "==========================================="
    echo "WireGuard Pi Client Setup (macOS)"
    echo "==========================================="
    echo ""

    # Install WireGuard tools (as regular user, no sudo)
    install_wireguard

    # Generate keys (always as regular user)
    generate_keys

    if [[ -z "$vps_pubkey" ]]; then
        echo ""
        log "Your Pi public key (share with VPS admin):"
        echo "  $PI_PUBLIC_KEY"
        echo ""
        warn "Run again with the VPS public key to activate:"
        echo "  sudo $0 <vps-public-key>"
        echo ""
        echo "Example:"
        echo "  sudo $0 eXaMpLeKeY1234567890abc..."
        exit 0
    fi

    # Write config (can be done without root)
    write_config "$vps_pubkey"

    # Install system-wide and bring up (needs root)
    install_config "$vps_pubkey"

    show_status
}

main "$@"
