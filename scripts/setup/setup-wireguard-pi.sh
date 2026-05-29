#!/bin/bash
# WireGuard Pi Client Setup for Linux/Raspberry Pi
# Tunnel: Pi 10.10.0.2 <-> VPS 10.10.0.1

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
    echo -e "${BLUE}║     WireGuard Pi Client Setup                      ║${NC}"
    echo -e "${BLUE}║     Secure tunnel for Pi ↔ VPS communication       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_help() {
    show_banner
    echo "Usage: sudo ./setup-wireguard-pi.sh"
    echo ""
    echo "This script will guide you through setting up WireGuard."
    echo "You'll need to run it twice:"
    echo ""
    echo "  1. First run:  Generate keys and configure Pi"
    echo "  2. Second run: Input VPS public key to complete setup"
    echo ""
}

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

# VPS public IP — can be passed as env var or argument
VPS_PUBLIC_IP="${VPS_PUBLIC_IP:-}"

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
        warn "Could not fetch public IP from ipify.org"
        return 1
    fi
    echo "$ip"
}

get_pi_public_ip() {
    log "Fetching Pi's public IP from ipify..."
    local pi_ip
    pi_ip=$(get_public_ip)
    if [[ $? -eq 0 ]]; then
        log "Pi public IP: $pi_ip"
        echo "$pi_ip"
    else
        warn "Failed to fetch Pi public IP"
        return 1
    fi
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

prompt_for_ip() {
    local prompt_msg="$1"
    local ip_input

    while true; do
        read -p "$prompt_msg: " ip_input

        # Validate IP format (basic check)
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
    info "=== WireGuard Status ==="
    echo ""
    wg show "$WG_IFACE" 2>/dev/null || warn "Interface not up yet"
    echo ""
    log "Pi tunnel IP:  10.10.0.2"
    log "VPS tunnel IP: 10.10.0.1"
    echo ""
    echo "Test connection:"
    echo "  ${YELLOW}ping 10.10.0.1${NC}"
    echo ""
    echo "View WireGuard status:"
    echo "  ${YELLOW}sudo wg show${NC}"
    echo ""
    log "Update your Pi .env:"
    echo "  VPS_API_URL=http://10.10.0.1:8080"
    echo "  VPS_WS_URL=ws://10.10.0.1:8080/ws/raspi"
}

show_first_run_intro() {
    echo ""
    info "=== STEP 1: Generate WireGuard Keys ==="
    echo ""
    echo "This is your first time running this script."
    echo "We will generate WireGuard keys for this Pi."
    echo ""
}

show_second_run_intro() {
    echo ""
    info "=== STEP 2: Configure WireGuard Connection ==="
    echo ""
    echo "Now we'll configure the connection to your VPS."
    echo ""
}

show_ip_options() {
    echo ""
    info "=== Network Configuration ==="
    echo ""
    echo "How would you like to provide the VPS IP?"
    echo ""
    echo "  1) Enter IP manually (from router/switch, or external VPS)"
    echo "  2) Auto-detect using ipify (if Pi is internet-connected)"
    echo ""
}

configure_vps_ip() {
    local vps_ip

    show_ip_options
    read -p "Choose option (1 or 2): " option

    case "$option" in
        1)
            echo ""
            echo "Where is your VPS located?"
            echo "  - On same local network (router/switch)? Enter local IP (e.g., 192.168.1.x)"
            echo "  - External VPS? Enter external/public IP"
            echo ""
            vps_ip=$(prompt_for_ip "Enter VPS IP address")
            ;;
        2)
            vps_ip=$(get_vps_public_ip) || error "Could not fetch VPS IP from ipify. Try option 1 instead."
            ;;
        *)
            error "Invalid option. Please choose 1 or 2."
            ;;
    esac

    VPS_PUBLIC_IP="$vps_ip"
    log "VPS IP configured: $VPS_PUBLIC_IP"
}

show_summary() {
    local pi_pubkey="$1"
    local pi_ip="$2"

    echo ""
    info "=== CONFIGURATION SUMMARY ==="
    echo ""
    echo "Pi Configuration:"
    echo "  Local Tunnel IP:  10.10.0.2/24"
    echo "  Public IP:        $pi_ip"
    echo "  Public Key:       ${pi_pubkey:0:20}..."
    echo ""
    echo "VPS Configuration:"
    echo "  Tunnel IP:        10.10.0.1/32"
    echo "  Public IP:        $VPS_PUBLIC_IP"
    echo ""
}

show_vps_instructions() {
    local pi_pubkey="$1"
    local pi_ip="$2"

    echo ""
    info "=== NEXT STEPS: Setup VPS Side ==="
    echo ""
    echo "Run the setup script on your VPS with these details:"
    echo ""
    echo "  ${YELLOW}./setup-wireguard-vps.sh${NC}"
    echo ""
    echo "You'll be asked for:"
    echo "  Pi Public Key:    $pi_pubkey"
    echo "  Pi Public IP:     $pi_ip"
    echo ""
}

main() {
    local vps_pubkey="${1:-}"
    local pi_public_ip
    local pi_pubkey

    show_banner

    # Setup dependencies
    detect_os
    check_dependencies
    install_wireguard

    # Generate keys
    generate_keys
    pi_pubkey=$(cat "$WG_DIR/publickey")

    # First run: Generate keys and get VPS IP
    if [[ -z "$vps_pubkey" ]]; then
        show_first_run_intro

        # Get Pi's public IP
        echo "Detecting Pi's public IP..."
        if pi_public_ip=$(get_pi_public_ip 2>/dev/null); then
            log "Detected: $pi_public_ip"
        else
            warn "Could not auto-detect Pi's public IP"
            pi_public_ip="<to be determined>"
        fi

        # Configure VPS IP
        configure_vps_ip

        # Show summary
        show_summary "$pi_pubkey" "$pi_public_ip"
        show_vps_instructions "$pi_pubkey" "$pi_public_ip"

        echo ""
        warn "Next: Run this script again with the VPS's public key:"
        echo "  ${YELLOW}sudo $0 <vps-public-key>${NC}"
        echo ""
        exit 0
    fi

    # Second run: Write config and enable
    show_second_run_intro

    if [[ -z "$VPS_PUBLIC_IP" ]]; then
        configure_vps_ip
    else
        log "Using VPS IP from environment: $VPS_PUBLIC_IP"
    fi

    log "Writing WireGuard configuration..."
    write_config "$vps_pubkey"
    enable_service
    test_tunnel
    show_status

    echo ""
    log "Setup complete!"
    echo ""
}

main "$@"
