#!/bin/bash
# WireGuard Pi client setup — runs on the Raspberry Pi
# Tunnel: Pi 10.10.0.2 <-> VPS 10.10.0.1

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root"

WG_IFACE="wg0"
PI_TUNNEL_IP="10.10.0.2/24"
VPS_TUNNEL_IP="10.10.0.1/32"
VPS_PORT="51820"
WG_DIR="/etc/wireguard"

# VPS public IP — update if it changes
VPS_PUBLIC_IP="${VPS_PUBLIC_IP:-178.104.6.176}"

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID,,}"
        OS_ID_LIKE="${ID_LIKE,,}"
    else
        error "Cannot detect OS: /etc/os-release not found"
    fi
}

install_wireguard() {
    log "Installing WireGuard..."
    detect_os

    case "$OS_ID" in
        ubuntu|debian|raspbian)
            apt-get update -qq
            apt-get install -y wireguard wireguard-tools
            ;;
        fedora)
            dnf install -y wireguard-tools
            ;;
        centos|rhel|almalinux|rocky)
            dnf install -y epel-release 2>/dev/null || yum install -y epel-release 2>/dev/null || true
            dnf install -y wireguard-tools 2>/dev/null || yum install -y wireguard-tools
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm wireguard-tools
            ;;
        alpine)
            apk add --no-cache wireguard-tools
            ;;
        *)
            if [[ "$OS_ID_LIKE" == *"debian"* ]]; then
                apt-get update -qq
                apt-get install -y wireguard wireguard-tools
            elif [[ "$OS_ID_LIKE" == *"rhel"* || "$OS_ID_LIKE" == *"fedora"* ]]; then
                dnf install -y wireguard-tools 2>/dev/null || yum install -y wireguard-tools
            elif [[ "$OS_ID_LIKE" == *"arch"* ]]; then
                pacman -Sy --noconfirm wireguard-tools
            else
                error "Unsupported OS: $OS_ID (ID_LIKE=$OS_ID_LIKE). Install wireguard-tools manually."
            fi
            ;;
    esac
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
