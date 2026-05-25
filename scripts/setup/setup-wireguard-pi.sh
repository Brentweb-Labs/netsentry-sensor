#!/bin/bash
# WireGuard Pi Client Setup for Linux/Raspberry Pi
# Tunnel: Pi 10.10.0.2 <-> VPS 10.10.0.1
#
# Usage:
#   1. First run:  sudo ./setup-wireguard-pi.sh
#      (outputs Pi public key to share with VPS)
#   2. Second run: sudo ./setup-wireguard-pi.sh <vps-public-key>

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

USAGE="
===========================================
WireGuard Pi Client Setup (Linux/Raspberry Pi)
===========================================

First run:
  sudo ./setup-wireguard-pi.sh

This outputs your Pi public key. Share it with the VPS admin.

Second run:
  sudo ./setup-wireguard-pi.sh <vps-public-key>
"
show_help() { echo "$USAGE"; }

# Parse args
case "${1:-}" in
    -h|--help) show_help; exit 0 ;;
esac

[[ $EUID -ne 0 ]] && error "Run as root"

WG_IFACE="wg0"
PI_TUNNEL_IP="10.10.0.2/24"
VPS_TUNNEL_IP="10.10.0.1/32"
VPS_PORT="51820"
WG_DIR="/etc/wireguard"

# VPS public IP — update if it changes
VPS_PUBLIC_IP="${VPS_PUBLIC_IP:-178.104.6.176}"

install_wireguard() {
    log "Installing WireGuard..."
    apt-get update -qq
    apt-get install -y wireguard wireguard-tools
}

generate_keys() {
    log "Generating Pi key pair..."
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    if [[ -f "$WG_DIR/privatekey" ]]; then
        warn "Keys already exist, skipping generation"
    else
        wg genkey | tee "$WG_DIR/privatekey" | wg pubkey > "$WG_DIR/publickey"
        chmod 600 "$WG_DIR/privatekey"
    fi

    PI_PRIVATE_KEY=$(cat "$WG_DIR/privatekey")
    PI_PUBLIC_KEY=$(cat "$WG_DIR/publickey")
    log "Pi public key: $PI_PUBLIC_KEY"
}

write_config() {
    local vps_pubkey="$1"

    log "Writing WireGuard client config..."
    cat > "$WG_DIR/$WG_IFACE.conf" << EOF
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
    chmod 600 "$WG_DIR/$WG_IFACE.conf"
}

enable_service() {
    log "Enabling and starting WireGuard..."
    systemctl enable "wg-quick@$WG_IFACE"
    systemctl restart "wg-quick@$WG_IFACE"
}

test_tunnel() {
    log "Testing tunnel to VPS..."
    sleep 3
    if ping -c 2 -W 3 10.10.0.1 >/dev/null 2>&1; then
        log "Tunnel working — VPS reachable at 10.10.0.1"
    else
        warn "Tunnel not responding yet — check VPS has Pi's public key configured"
    fi
}

show_status() {
    echo ""
    log "WireGuard Pi status:"
    wg show "$WG_IFACE" 2>/dev/null || warn "Interface not up yet"
    echo ""
    log "Pi tunnel IP:  10.10.0.2"
    log "VPS tunnel IP: 10.10.0.1"
    echo ""
    log "Update your Pi .env:"
    echo "  VPS_API_URL=http://10.10.0.1:8080"
    echo "  VPS_WS_URL=ws://10.10.0.1:8080/ws/raspi"
}

main() {
    local vps_pubkey="${1:-}"

    install_wireguard
    generate_keys

    if [[ -z "$vps_pubkey" ]]; then
        echo ""
        log "Pi public key (give this to the VPS setup script):"
        echo "  $(cat $WG_DIR/publickey)"
        echo ""
        warn "Run again with the VPS's public key to finish setup:"
        echo "  $0 <vps-public-key>"
        exit 0
    fi

    write_config "$vps_pubkey"
    enable_service
    test_tunnel
    show_status
}

main "$@"
