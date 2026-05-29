#!/bin/bash
# WireGuard VPS Server Setup for Linux
# Tunnel: VPS 10.10.0.1 <-> Pi 10.10.0.2

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[SETUP]${NC} $1"; }

show_banner() {
    clear
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     WireGuard VPS Server Setup                     ║${NC}"
    echo -e "${BLUE}║     Secure tunnel for VPS ↔ Pi communication       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_help() {
    show_banner
    echo "Usage: sudo ./setup-wireguard-vps.sh"
    echo ""
    echo "This script will guide you through setting up WireGuard on the VPS."
    echo "You'll need to run it twice:"
    echo ""
    echo "  1. First run:  Generate keys and get VPS public key"
    echo "  2. Second run: Input Pi public key to complete setup"
    echo ""
}

# Parse args
case "${1:-}" in
    -h|--help) show_help; exit 0 ;;
esac

[[ $EUID -ne 0 ]] && error "Run as root"

WG_IFACE="wg0"
VPS_TUNNEL_IP="10.10.0.1/24"
PI_TUNNEL_IP="10.10.0.2/32"
WG_PORT="51820"
WG_DIR="/etc/wireguard"
PI_PUBLIC_IP="${PI_PUBLIC_IP:-}"

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID,,}"
        OS_ID_LIKE="${ID_LIKE,,}"
    else
        error "Cannot detect OS: /etc/os-release not found"
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -s https://api.ipify.org?format=json | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
    if [[ -z "$ip" ]]; then
        return 1
    fi
    echo "$ip"
}

get_vps_public_ip() {
    log "Fetching VPS public IP from ipify..."
    local vps_ip
    vps_ip=$(get_public_ip)
    if [[ $? -eq 0 ]]; then
        log "VPS public IP: $vps_ip"
        echo "$vps_ip"
    else
        warn "Failed to fetch VPS public IP"
        return 1
    fi
}

check_dependencies() {
    log "Checking dependencies..."
    if ! command -v curl &> /dev/null; then
        warn "curl not found, installing..."
        detect_os
        case "$OS_ID" in
            ubuntu|debian|raspbian)
                apt-get update -qq
                apt-get install -y curl
                ;;
            fedora|centos|rhel|almalinux|rocky)
                dnf install -y curl 2>/dev/null || yum install -y curl
                ;;
            arch|manjaro)
                pacman -Sy --noconfirm curl
                ;;
            alpine)
                apk add --no-cache curl
                ;;
            *)
                error "Please install curl manually"
                ;;
        esac
    fi
}

prompt_for_ip() {
    local prompt_msg="$1"
    local ip_input

    while true; do
        read -p "$prompt_msg: " ip_input

        if [[ $ip_input =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip_input"
            return 0
        else
            warn "Invalid IP format. Please enter a valid IPv4 address (e.g., 192.168.1.100)"
        fi
    done
}

prompt_yes_no() {
    local prompt_msg="$1"
    local response

    while true; do
        read -p "$prompt_msg (yes/no): " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]) return 1 ;;
            *) warn "Please answer yes or no" ;;
        esac
    done
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

show_first_run_intro() {
    echo ""
    info "=== STEP 1: Generate WireGuard Keys ==="
    echo ""
    echo "This is your first time running this script."
    echo "We will generate WireGuard keys for this VPS server."
    echo ""
}

show_second_run_intro() {
    echo ""
    info "=== STEP 2: Configure WireGuard for Pi Connection ==="
    echo ""
    echo "Now we'll configure the connection to accept the Pi."
    echo ""
}

show_ip_options() {
    echo ""
    info "=== Network Configuration ==="
    echo ""
    echo "How would you like to provide the Pi IP?"
    echo ""
    echo "  1) Enter IP manually (from router/switch, or external Pi)"
    echo "  2) Auto-detect using ipify (if Pi is internet-connected)"
    echo ""
}

configure_pi_ip() {
    local pi_ip

    show_ip_options
    read -p "Choose option (1 or 2): " option

    case "$option" in
        1)
            echo ""
            echo "Where is your Pi located?"
            echo "  - On same local network (router/switch)? Enter local IP (e.g., 192.168.1.x)"
            echo "  - External Pi? Enter external/public IP"
            echo ""
            pi_ip=$(prompt_for_ip "Enter Pi IP address")
            ;;
        2)
            pi_ip=$(get_vps_public_ip) || error "Could not fetch Pi IP from ipify. Try option 1 instead."
            ;;
        *)
            error "Invalid option. Please choose 1 or 2."
            ;;
    esac

    PI_PUBLIC_IP="$pi_ip"
    log "Pi IP configured: $PI_PUBLIC_IP"
}

show_summary() {
    local vps_pubkey="$1"
    local vps_ip="$2"

    echo ""
    info "=== CONFIGURATION SUMMARY ==="
    echo ""
    echo "VPS Configuration:"
    echo "  Local Tunnel IP:  10.10.0.1/24"
    echo "  Public IP:        $vps_ip"
    echo "  Public Key:       ${vps_pubkey:0:20}..."
    echo "  Listen Port:      51820/udp"
    echo ""
    echo "Pi Configuration:"
    echo "  Tunnel IP:        10.10.0.2/32"
    echo "  Public IP:        $PI_PUBLIC_IP"
    echo ""
}

show_pi_instructions() {
    local vps_pubkey="$1"
    local vps_ip="$2"

    echo ""
    info "=== NEXT STEPS: Setup Pi Side ==="
    echo ""
    echo "Run the setup script on your Pi with these details:"
    echo ""
    echo "  ${YELLOW}./setup-wireguard-pi.sh${NC}"
    echo ""
    echo "When prompted, provide:"
    echo "  VPS Public Key:   $vps_pubkey"
    echo "  VPS Public IP:    $vps_ip"
    echo ""
}

show_status() {
    echo ""
    info "=== WireGuard Status ==="
    echo ""
    wg show "$WG_IFACE" 2>/dev/null || warn "Interface not up yet"
    echo ""
    log "VPS tunnel IP: 10.10.0.1"
    log "Pi tunnel IP:  10.10.0.2"
    echo ""
    echo "Test connection:"
    echo "  ${YELLOW}ping 10.10.0.2${NC}"
    echo ""
    echo "View WireGuard status:"
    echo "  ${YELLOW}sudo wg show${NC}"
    echo ""
    log "Update your VPS .env:"
    echo "  RASPI_ENDPOINT=http://10.10.0.2:8080"
    echo ""
    log "Then restart the api-gateway:"
    echo "  docker compose -f docker-compose.vps.yml up -d --no-deps api-gateway"
}

main() {
    local pi_pubkey="${1:-}"
    local vps_pubkey
    local vps_public_ip

    show_banner

    # Check root
    [[ $EUID -ne 0 ]] && error "Run as root"

    # Setup dependencies
    detect_os
    check_dependencies
    install_wireguard

    # Generate keys
    generate_keys
    vps_pubkey=$(cat "$WG_DIR/publickey")

    # First run: Generate keys and get Pi IP
    if [[ -z "$pi_pubkey" ]]; then
        show_first_run_intro

        # Get VPS's public IP
        echo "Detecting VPS public IP..."
        if vps_public_ip=$(get_vps_public_ip 2>/dev/null); then
            log "Detected: $vps_public_ip"
        else
            warn "Could not auto-detect VPS public IP"
            vps_public_ip="<to be determined>"
        fi

        # Configure Pi IP
        configure_pi_ip

        # Show summary
        show_summary "$vps_pubkey" "$vps_public_ip"
        show_pi_instructions "$vps_pubkey" "$vps_public_ip"

        echo ""
        warn "Next: Run this script again with the Pi's public key:"
        echo "  ${YELLOW}sudo $0 <pi-public-key>${NC}"
        echo ""
        exit 0
    fi

    # Second run: Write config and enable
    show_second_run_intro

    if [[ -z "$PI_PUBLIC_IP" ]]; then
        configure_pi_ip
    else
        log "Using Pi IP from environment: $PI_PUBLIC_IP"
    fi

    log "Writing WireGuard configuration..."
    write_config "$pi_pubkey"
    open_firewall
    enable_service
    show_status

    echo ""
    log "Setup complete!"
    echo ""
}

main "$@"
