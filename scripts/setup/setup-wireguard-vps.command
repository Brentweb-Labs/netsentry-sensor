#!/bin/bash
# WireGuard VPS Server Setup for macOS
# Tunnel: VPS 10.10.0.1 <-> Pi 10.10.0.2
#
# Usage:
#   1. First run:  ./setup-wireguard-vps.command
#      (outputs VPS public key to share with Pi)
#   2. Second run: sudo ./setup-wireguard-vps.command <pi-public-key>
#
# Requirements:
#   - Homebrew: https://brew.sh
#   - WireGuard: https://www.wireguard.com/install/
#   - sudo access for system-wide config installation

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

WG_IFACE="utun"
VPS_TUNNEL_IP="10.10.0.1/24"
PI_TUNNEL_IP="10.10.0.2/32"
WG_PORT="51820"

# Config location (no root needed for generation)
WG_DIR="$HOME/Library/Application Support/WireGuard"
mkdir -p "$WG_DIR"

USAGE="
===========================================
WireGuard VPS Server Setup for macOS
===========================================

First run (as your user):
  ./setup-wireguard-vps.command

This outputs your VPS public key. Share it with the Pi admin.

Second run (with sudo):
  sudo ./setup-wireguard-vps.command <pi-public-key>

Example:
  sudo ./setup-wireguard-vps.command ABCDEF12345...
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
    log "Generating VPS key pair..."

    local privatekey_file="$WG_DIR/privatekey"
    local publickey_file="$WG_DIR/publickey"

    if [[ -f "$privatekey_file" && -f "$publickey_file" ]]; then
        warn "Keys already exist, skipping generation"
    else
        wg genkey | tee "$privatekey_file" | wg pubkey > "$publickey_file"
        chmod 600 "$privatekey_file"
    fi

    VPS_PRIVATE_KEY=$(cat "$privatekey_file")
    VPS_PUBLIC_KEY=$(cat "$publickey_file")
    log "VPS public key generated: $VPS_PUBLIC_KEY"
}

write_config() {
    local pi_pubkey="$1"
    [[ -z "$pi_pubkey" ]] && error "Usage: sudo $0 <pi-public-key>"

    log "Writing WireGuard server config..."
    local conf_file="$WG_DIR/wg0.conf"

    cat > "$conf_file" << EOF
[Interface]
Address = $VPS_TUNNEL_IP
ListenPort = $WG_PORT
PrivateKey = $VPS_PRIVATE_KEY

# Raspberry Pi
[Peer]
PublicKey = $pi_pubkey
AllowedIPs = $PI_TUNNEL_IP
PersistentKeepalive = 25
EOF
    chmod 600 "$conf_file"
    log "Config written to: $conf_file"
}

open_firewall() {
    log "Configuring firewall for port $WG_PORT/udp..."

    # Check if WireGuard port is already allowed
    if command -v pfctl >/dev/null 2>&1; then
        if pfctl -s rules 2>/dev/null | grep -q "port $WG_PORT"; then
            log "Firewall rule already exists"
            return 0
        fi
    fi

    # Note: macOS firewall configuration requires manual steps
    echo ""
    warn "To enable incoming WireGuard connections:"
    echo "  1. Open System Settings → Network → Firewall"
    echo "  2. Enable firewall if not already"
    echo "  3. Add exception for WireGuard or UDP port $WG_PORT"
    echo ""
    log "Or run these commands in Terminal:"
    echo "  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --addapp=/usr/local/bin/wg"
    echo "  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unlockapp=/usr/local/bin/wg"
}

install_config() {
    local pi_pubkey="$1"
    log "Installing config to system location..."

    local system_wg_dir="/etc/wireguard"
    local system_conf="$system_wg_dir/wg0.conf"

    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root - config stays in user directory"
        log "To activate the server, run with sudo:"
        echo "  sudo ./setup-wireguard-vps.command $pi_pubkey"
        return 0
    fi

    # Root can install system-wide
    mkdir -p "$system_wg_dir"
    chmod 700 "$system_wg_dir"

    cp "$WG_DIR/wg0.conf" "$system_conf"
    chmod 600 "$system_conf"

    # Bring up tunnel
    log "Activating WireGuard server..."
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
    echo "  VPS tunnel IP:  10.10.0.1"
    echo "  Pi tunnel IP:   10.10.0.2"
    echo "  Listen Port:    $WG_PORT/udp"
    echo ""

    if [[ $EUID -eq 0 ]]; then
        echo "Server Status:"
        wg show 2>/dev/null || warn "Server not yet active"
    else
        echo "Next Steps:"
        echo "  1. Run with sudo to activate the server"
        echo "  2. Or use the WireGuard app to import: $WG_DIR/wg0.conf"
    fi

    echo ""
    log "Update your VPS .env:"
    echo "  RASPI_ENDPOINT=http://10.10.0.2:8080"
    echo ""
    log "Then restart the api-gateway:"
    echo "  docker compose -f docker-compose.vps.yml up -d --no-deps api-gateway"
}

main() {
    local pi_pubkey="${1:-}"

    # Check if help requested
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        show_help
        exit 0
    fi

    echo "==========================================="
    echo "WireGuard VPS Server Setup (macOS)"
    echo "==========================================="
    echo ""

    # Install WireGuard tools (as regular user, no sudo)
    install_wireguard

    # Generate keys (always as regular user)
    generate_keys

    if [[ -z "$pi_pubkey" ]]; then
        echo ""
        log "Your VPS public key (share with Pi admin):"
        echo "  $VPS_PUBLIC_KEY"
        echo ""
        warn "Run again with the Pi public key to activate:"
        echo "  sudo $0 <pi-public-key>"
        echo ""
        echo "Example:"
        echo "  sudo $0 eXaMpLeKeY1234567890abc..."
        exit 0
    fi

    # Write config (can be done without root)
    write_config "$pi_pubkey"

    # Configure firewall and install system-wide (needs root)
    open_firewall
    install_config "$pi_pubkey"

    show_status
}

main "$@"
