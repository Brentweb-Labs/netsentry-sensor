#!/bin/bash
#
# revert-bridge.sh - Revert Pi from gateway/bridge to passive sensor
#
# Usage: ./revert-bridge.sh [revert|status|help]
#
# This script removes the bridge/NAT configuration from the Raspberry Pi,
# converting it from an inline gateway to a passive sensor for SPAN topology.
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

# Get current bridge status
get_bridge_status() {
    log_info "Checking current network configuration..."

    # Check if IP forwarding is enabled
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = "1" ]; then
        log_warn "IP forwarding is ENABLED"
    else
        log_success "IP forwarding is disabled"
    fi

    # Check bridge interfaces
    if command -v brctl >/dev/null 2>&1; then
        if brctl show 2>/dev/null | grep -q "br0"; then
            log_warn "Bridge br0 exists"
            brctl show
        else
            log_success "No bridge interface found"
        fi
    elif command -v ip >/dev/null 2>&1; then
        if ip link show type bridge 2>/dev/null | grep -q "br0"; then
            log_warn "Bridge br0 exists"
            ip link show type bridge
        else
            log_success "No bridge interface found"
        fi
    fi

    # Check NAT rules
    if iptables -t nat -L -n 2>/dev/null | grep -q "MASQUERADE"; then
        log_warn "NAT MASQUERADE rules exist"
    else
        log_success "No NAT rules found"
    fi
}

# Revert bridge configuration
revert_bridge() {
    log_info "Reverting Pi from gateway to passive sensor..."

    # Disable IP forwarding
    log_info "Disabling IP forwarding..."
    echo 0 > /proc/sys/net/ipv4/ip_forward
    # Make persistent
    if [ -f /etc/sysctl.conf ]; then
        sed -i 's/^net.ipv4.ip_forward=1/#net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null || true
    fi
    log_success "IP forwarding disabled"

    # Remove bridge interface if it exists
    if command -v ip >/dev/null 2>&1; then
        if ip link show br0 >/dev/null 2>&1; then
            log_info "Removing bridge br0..."
            ip link set br0 down 2>/dev/null || true
            ip link delete br0 2>/dev/null || true
            log_success "Bridge br0 removed"
        fi

        # Remove eth1 from any bridge if it was part of one
        for br in $(ip link show type bridge | grep -oP '^\d+:\s+\K[^:]+' || true); do
            if ip link show "$br" | grep -q "eth1"; then
                log_info "Removing eth1 from bridge $br..."
                ip link set eth1 nomaster 2>/dev/null || true
            fi
        done
    elif command -v brctl >/dev/null 2>&1; then
        if brctl show | grep -q "br0"; then
            log_info "Removing bridge br0..."
            brctl delif br0 eth1 2>/dev/null || true
            brctl delif br0 eth0 2>/dev/null || true
            brctl delbr br0 2>/dev/null || true
            log_success "Bridge br0 removed"
        fi
    fi

    # Clear NAT rules
    log_info "Clearing NAT rules..."
    iptables -t nat -F 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    log_success "NAT rules cleared"

    # Clear forwarding rules (preserve default policies)
    log_info "Clearing forwarding rules..."
    iptables -F FORWARD 2>/dev/null || true
    log_success "Forwarding rules cleared"

    # Enable eth0 and eth1 (may already be up)
    log_info "Ensuring network interfaces are up..."
    ip link set eth0 up 2>/dev/null || true
    ip link set eth1 up 2>/dev/null || true
    log_success "Network interfaces configured"

    # Show final status
    log_info "Final configuration:"
    echo ""
    echo "  IP Forwarding: $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
    echo "  Bridge interfaces:"
    ip link show type bridge 2>/dev/null | grep -E "^[0-9]+:" || echo "    (none)"
    echo "  NAT rules:"
    iptables -t nat -L -n 2>/dev/null | grep -c "MASQUERADE" || echo "    (none)"

    echo ""
    log_success "Bridge reverted! Pi is now a passive sensor."
    log_info ""
    log_info "Next steps:"
    log_info "  1. Configure your TP-Link TL-SG108E for port mirroring"
    log_info "  2. Connect Pi to Port 8 of the switch"
    log_info "  3. Run: ./setup-span-port.sh verify"
    log_info "  4. Ensure router (192.168.1.1) handles DHCP/gateway duties"
}

# Show help
show_help() {
    cat << EOF
Revert Pi from gateway/bridge to passive sensor

USAGE:
    $0 [revert|status|help]

DESCRIPTION:
    Removes the bridge/NAT configuration from the Raspberry Pi,
    converting it from an inline gateway to a passive sensor
    for out-of-band SPAN/mirror port monitoring.

    This is REQUIRED before deploying the SPAN topology because:
    - The Pi no longer handles IP forwarding
    - The Pi no longer does NAT
    - The Pi no longer acts as DHCP server
    - Traffic blocking moves to the router/firewall

PREREQUISITES:
    - Must run as root (sudo $0 revert)
    - Router must be configured as gateway/DHCP server
    - DHCP reservation for Pi should be set on router

EXAMPLES:
    sudo $0 revert     # Remove bridge/gateway config
    sudo $0 status     # Check current configuration
    sudo $0 help       # Show this help message
EOF
}

# Main
case "${1:-help}" in
    revert)
        check_root
        revert_bridge
        ;;
    status)
        get_bridge_status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
