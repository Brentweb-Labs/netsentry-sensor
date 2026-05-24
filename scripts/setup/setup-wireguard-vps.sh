#!/bin/bash
# WireGuard VPS server setup — runs on the Hetzner VPS
# Tunnel: VPS 10.10.0.1 <-> Pi 10.10.0.2

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
VPS_TUNNEL_IP="10.10.0.1/24"
PI_TUNNEL_IP="10.10.0.2/32"
WG_PORT="51820"
WG_DIR="/etc/wireguard"

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
            # WireGuard is in EPEL for RHEL-family
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
            # Fall back to ID_LIKE if the specific distro isn't matched
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
    log "Generating VPS key pair..."
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    if [[ -f "$WG_DIR/privatekey" ]]; then
        warn "Keys already exist, skipping generation"
    else
        wg genkey | tee "$WG_DIR/privatekey" | wg pubkey > "$WG_DIR/publickey"
        chmod 600 "$WG_DIR/privatekey"
    fi

    VPS_PRIVATE_KEY=$(cat "$WG_DIR/privatekey")
    VPS_PUBLIC_KEY=$(cat "$WG_DIR/publickey")
    log "VPS public key: $VPS_PUBLIC_KEY"
}

write_config() {
    local pi_pubkey="$1"

    log "Writing WireGuard server config..."
    cat > "$WG_DIR/$WG_IFACE.conf" << EOF
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
    chmod 600 "$WG_DIR/$WG_IFACE.conf"
}

open_firewall() {
    log "Opening WireGuard port $WG_PORT/udp..."
    iptables -A INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || true
    # Persist if iptables-persistent is installed
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save 2>/dev/null || true
    fi
}

enable_service() {
    log "Enabling and starting WireGuard..."
    systemctl enable "wg-quick@$WG_IFACE"
    systemctl restart "wg-quick@$WG_IFACE"
}

show_status() {
    echo ""
    log "WireGuard VPS status:"
    wg show "$WG_IFACE" 2>/dev/null || warn "Interface not up yet"
    echo ""
    log "VPS tunnel IP: 10.10.0.1"
    log "Pi tunnel IP:  10.10.0.2"
    echo ""
    log "Update your VPS .env:"
    echo "  RASPI_ENDPOINT=http://10.10.0.2:8080"
    echo ""
    log "Then restart the api-gateway:"
    echo "  docker compose -f docker-compose.vps.yml up -d --no-deps api-gateway"
}

main() {
    local pi_pubkey="${1:-}"

    install_wireguard
    generate_keys

    if [[ -z "$pi_pubkey" ]]; then
        echo ""
        log "VPS public key (give this to the Pi setup script):"
        echo "  $(cat $WG_DIR/publickey)"
        echo ""
        warn "Run again with the Pi's public key to finish setup:"
        echo "  $0 <pi-public-key>"
        exit 0
    fi

    write_config "$pi_pubkey"
    open_firewall
    enable_service
    show_status
}

main "$@"
