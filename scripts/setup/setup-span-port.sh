#!/bin/bash
#
# setup-span-port.sh - Configure Managed Switch for Port Mirroring (SPAN)
#
# This script helps configure a managed network switch to mirror traffic
# to the Raspberry Pi IDPS sensor for out-of-band monitoring.
#
# Usage: ./setup-span-port.sh [configure|status|help]
#
# Prerequisites:
#   - Managed network switch with port mirroring/SPAN support
#   - Switch must be accessible on network (IP varies by device)
#   - Admin credentials to access switch web UI or CLI
#
# Topology:
#   [Modem] ──► [Router] ──► [Managed Switch (Port Mirroring)]
#                                      │
#              ┌───────────────────────┼─────────────────┐
#              │         Source Ports  │                 │
#              │   (Router, Wi-Fi, etc)│                 │
#              │    Mirror Destination │◄── Mirrored traffic
#              └───────────────────────┴─────────────────┘
#

set -euo pipefail

# Configuration
SWITCH_IP="${SWITCH_IP:-192.168.0.1}"
SWITCH_USER="${SWITCH_USER:-admin}"
SWITCH_PASS="${SWITCH_PASS:-admin}"
IDPS_INTERFACE="${IDPS_INTERFACE:-eth0}"
IDPS_IP="${IDPS_IP:-192.168.1.100}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Show help
show_help() {
    cat << EOF
Managed Switch Port Mirroring (SPAN) Setup for IDPS

USAGE:
    $0 [configure|status|help]

DESCRIPTION:
    Helps configure a managed network switch to mirror traffic
    to the Raspberry Pi for out-of-band network monitoring.

    IMPORTANT: This script provides instructions and verification.
    The actual port mirroring configuration must be done via your
    switch's web UI or CLI (location varies by manufacturer).

CONFIGURATION STEPS (varies by switch):

    1. Access your switch web UI or CLI
    2. Navigate to port mirroring/SPAN configuration
       (Location depends on manufacturer)
    3. Enable Port Mirroring/SPAN
    4. Set Source Ports: Select ports to monitor
    5. Set Mirror Destination: Port where Pi is connected
    6. Save/Apply configuration

ENVIRONMENT VARIABLES:
    SWITCH_IP      IP address of switch (default: 192.168.0.1)
    SWITCH_USER    Admin username (default: admin)
    SWITCH_PASS    Admin password (default: admin)
    IDPS_INTERFACE Network interface for capture (default: eth0)
    IDPS_IP        IP address of Raspberry Pi

EXAMPLES:
    $0 configure     # Show configuration steps
    $0 status        # Check current network connectivity to switch
    $0 help          # Show this help message
EOF
}

# Check connectivity to the switch
check_switch_connectivity() {
    log_info "Checking connectivity to switch at ${SWITCH_IP}..."

    if ping -c 1 -W 2 "${SWITCH_IP}" >/dev/null 2>&1; then
        log_success "Switch is reachable at ${SWITCH_IP}"
        return 0
    else
        log_warn "Switch is not reachable at ${SWITCH_IP}"
        log_info "The switch IP may be different. Check your network."
        log_info "Common switch IPs: 192.168.0.1, 192.168.1.1, 192.168.100.1, 10.0.0.1"
        return 1
    fi
}

# Check if we can see traffic on the IDPS interface
check_idps_interface() {
    log_info "Checking IDPS interface ${IDPS_INTERFACE}..."

    if ip link show "${IDPS_INTERFACE}" >/dev/null 2>&1; then
        log_success "Interface ${IDPS_INTERFACE} exists"

        # Check if interface is up
        if ip link show "${IDPS_INTERFACE}" | grep -q "state UP"; then
            log_success "Interface ${IDPS_INTERFACE} is UP"

            # Show current stats
            if command -v ifstat >/dev/null 2>&1; then
                log_info "Current traffic stats:"
                ifstat -i "${IDPS_INTERFACE}" 1 1 2>/dev/null || true
            fi
            return 0
        else
            log_warn "Interface ${IDPS_INTERFACE} exists but is not UP"
            log_info "Bring it up with: sudo ip link set ${IDPS_INTERFACE} up"
            return 1
        fi
    else
        log_error "Interface ${IDPS_INTERFACE} not found"
        log_info "Available interfaces:"
        ip -br link show | grep -v "^lo" || true
        return 1
    fi
}

# Show network topology diagram
show_topology() {
    cat << EOF

${GREEN}CURRENT NETWORK TOPOLOGY:${NC}

    ┌─────────────────────────────────────────────────────────┐
    │           Managed Switch (Port Mirroring Enabled)       │
    └─────────────────────┬───────────────────────────────────┘
                          │
    ┌─────────────────────┼────────────────────┬──────────────┐
    │                     │                    │              │
    ▼                     ▼                    ▼              │
Source  ────────────► Source ────────────► ... ────► Mirror   │
Ports 1,2, etc        (Router, Wi-Fi)          │   Destination
                                               │
                                               ▼
                                    ┌───────────────────┐
                                    │  Raspberry Pi     │
                                    │  ${IDPS_IP}      │
                                    │  eth0 (monitor)   │
                                    └───────────────────┘

${YELLOW}Verification Commands:${NC}
    # Verify you're receiving mirrored traffic:
    sudo tcpdump -i ${IDPS_INTERFACE} -c 10

    # Watch packet count:
    watch -n1 'cat /sys/class/net/${IDPS_INTERFACE}/statistics/rx_packets'

EOF
}

# Verify we're receiving mirrored traffic
verify_mirror() {
    log_info "Verifying port mirroring is working..."

    # Get initial packet count
    local initial_rx
    initial_rx=$(cat /sys/class/net/${IDPS_INTERFACE}/statistics/rx_packets 2>/dev/null || echo "0")
    log_info "Initial RX packets: ${initial_rx}"

    log_info "Waiting 5 seconds for traffic..."
    sleep 5

    local final_rx
    final_rx=$(cat /sys/class/net/${IDPS_INTERFACE}/statistics/rx_packets 2>/dev/null || echo "0")
    log_info "Final RX packets: ${final_rx}"

    local diff=$((final_rx - initial_rx))
    log_info "Packets received in 5s: ${diff}"

    if [ "${diff}" -gt 0 ]; then
        log_success "Port mirroring is working! Receiving traffic on ${IDPS_INTERFACE}"
        return 0
    else
        log_error "No traffic received on ${IDPS_INTERFACE}"
        log_info "Troubleshooting steps:"
        log_info "  1. Verify switch port mirroring is enabled in web UI"
        log_info "  2. Check cable connections (Port 8 to Pi)"
        log_info "  3. Confirm Ports 1+2 are set as Monitored Ports"
        return 1
    fi
}

# Main configuration display
configure() {
    cat << EOF

${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}
${GREEN}║          Managed Switch Port Mirroring Configuration for IDPS         ║${NC}
${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}

This script helps you configure port mirroring on your managed network switch.

Switch Access:
  - IP:     ${SWITCH_IP}
  - User:   ${SWITCH_USER}
  - Pass:   ${SWITCH_PASS}

${YELLOW}STEP 1: Access Switch Web UI or CLI${NC}
Open your browser and navigate to:
    http://${SWITCH_IP}
Or use CLI/SSH to access your switch.
Log in with the admin credentials.

${YELLOW}STEP 2: Navigate to Port Mirroring Configuration${NC}
The location depends on your switch manufacturer:
  - TP-Link: Features → Port Mirroring
  - Netgear: Administration → Port Mirroring
  - D-Link: Advanced → Port Mirroring
  - Ubiquiti: Settings → Port Mirroring
  - Cisco/Arista: Monitor Sessions (CLI)

${YELLOW}STEP 3: Configure Mirroring${NC}
Set the following (layout varies by switch):
    ┌─────────────────────────────────────────────┐
    │ Port Mirroring/SPAN:  ○ Disable  ● Enable  │
    │                                               │
    │ Source Ports (traffic to monitor):          │
    │   ☑ Port 1  (Router/Uplink)                  │
    │   ☑ Port 2  (Wi-Fi AP)                       │
    │   ☐ Port 3-N (other ports to monitor)        │
    │                                               │
    │ Destination Port (where Pi is connected):   │
    │   ● Port X  (Raspberry Pi)                   │
    │                                               │
    │ Click: Save/Apply                            │
    └─────────────────────────────────────────────┘

${YELLOW}STEP 4: Verify on Pi${NC}
After saving, run:
    $0 verify

${BLUE}Advanced: CLI Configuration${NC}
If your switch supports CLI, refer to vendor documentation:
  - TP-Link: monitor port [src_port] to [dst_port]
  - Netgear: monitor session [num] source [ports] dest [port]
  - D-Link: See switch documentation

EOF
}

# Main
case "${1:-help}" in
    configure|config)
        configure
        ;;
    status)
        check_switch_connectivity || true
        check_idps_interface || true
        show_topology
        ;;
    verify)
        check_idps_interface
        verify_mirror
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
