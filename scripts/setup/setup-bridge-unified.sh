#!/bin/bash

# Unified Raspberry Pi Network Bridge Setup for IDPS
# This script combines all bridge setup, fixes, and recovery functions

set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
BRIDGE_NAME="br0"
WAN_INTERFACE="eth0"
LAN_INTERFACE="eth1"
WAN_IP="" # Will be assigned by DHCP from modem
LAN_IP="192.168.100.1"
LAN_NETMASK="255.255.255.0"
DHCP_RANGE="192.168.100.100,192.168.100.200"
LOG_FILE="/var/log/idps-bridge-debug.log"
LINK_MONITOR_LOG="/tmp/idps-bridge-link.log"

# DHCP client wrapper — tries available clients in order
dhcp_request() {
    local iface="$1"
    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd "$iface"
    elif command -v udhcpc >/dev/null 2>&1; then
        udhcpc -i "$iface"
    elif command -v nmcli >/dev/null 2>&1; then
        nmcli device connect "$iface"
    else
        error "No DHCP client found (tried dhcpcd, udhcpc, nmcli)"
        return 1
    fi
}

# Prefer to keep LAN interface unmanaged by NetworkManager so it doesn't bounce it
set_unmanaged_if_possible() {
    if command -v nmcli >/dev/null 2>&1; then
        if nmcli dev status 2>/dev/null | grep -q "^$LAN_INTERFACE"; then
            log "Marking $LAN_INTERFACE as unmanaged in NetworkManager"
            nmcli dev set "$LAN_INTERFACE" managed no 2>/dev/null || warn "Failed to mark $LAN_INTERFACE unmanaged"
        fi
    fi
}

# Kill DHCP clients on LAN interface to avoid it being torn down
stop_lan_dhcp_clients() {
    dhcp_release "$LAN_INTERFACE"
    if pgrep -a dhcpcd 2>/dev/null | grep -q "$LAN_INTERFACE"; then
        warn "Stopping dhcpcd on $LAN_INTERFACE"
        dhcpcd -k "$LAN_INTERFACE" 2>/dev/null || true
    fi
    if pgrep -a dhclient 2>/dev/null | grep -q "$LAN_INTERFACE"; then
        warn "Stopping dhclient on $LAN_INTERFACE"
        pkill -f "dhclient.*$LAN_INTERFACE" 2>/dev/null || true
    fi
}

# Short-lived link monitor to catch drops right after setup
start_link_monitor() {
    : > "$LINK_MONITOR_LOG"
    ( timeout 20 ip monitor link >> "$LINK_MONITOR_LOG" 2>&1 ) &
    LINK_MONITOR_PID=$!
}

stop_link_monitor() {
    if [[ -n "${LINK_MONITOR_PID:-}" ]]; then
        kill "$LINK_MONITOR_PID" 2>/dev/null || true
        wait "$LINK_MONITOR_PID" 2>/dev/null || true
        LINK_MONITOR_PID=""
        log "Recent link events (if any):"
        tail -n 50 "$LINK_MONITOR_LOG" 2>/dev/null || true
    fi
}

# Capture a snapshot for post-setup debugging
debug_snapshot() {
    local reason="$1"
    echo "===== DEBUG SNAPSHOT: $reason =====" | tee -a "$LOG_FILE"
    date | tee -a "$LOG_FILE"
    echo "-- ip link --" | tee -a "$LOG_FILE"
    ip link show | tee -a "$LOG_FILE"
    echo "-- bridge link --" | tee -a "$LOG_FILE"
    bridge link show | tee -a "$LOG_FILE"
    echo "-- addresses --" | tee -a "$LOG_FILE"
    ip addr show | tee -a "$LOG_FILE"
    echo "-- routes --" | tee -a "$LOG_FILE"
    ip route show | tee -a "$LOG_FILE"
    echo "-- dmesg (tail) --" | tee -a "$LOG_FILE"
    dmesg | tail -n 50 | tee -a "$LOG_FILE"
    if command -v journalctl >/dev/null 2>&1 && systemctl list-units | grep -q NetworkManager; then
        echo "-- NetworkManager (tail) --" | tee -a "$LOG_FILE"
        journalctl -u NetworkManager -n 50 --no-pager 2>/dev/null | tee -a "$LOG_FILE"
    fi
    echo "===== END SNAPSHOT =====" | tee -a "$LOG_FILE"
}

dhcp_release() {
    local iface="${1:-}"
    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -k ${iface:+"$iface"} 2>/dev/null || true
    elif command -v nmcli >/dev/null 2>&1 && [[ -n "$iface" ]]; then
        nmcli device disconnect "$iface" 2>/dev/null || true
    fi
}

# Functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
       error "This script must be run as root"
       exit 1
    fi
}

# Enable debug logging to file (best effort)
init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Debug log: $LOG_FILE"
}

# Show usage
show_usage() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  setup     - Setup bridge (default)"
    echo "  revert    - Revert all changes"
    echo "  status    - Show current status"
    echo "  fix-dns   - Fix DNS issues"
    echo "  troubleshoot - Troubleshoot connection issues"
    echo "  help      - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 setup    # Setup bridge"
    echo "  $0 revert   # Remove bridge and restore network"
    echo "  $0 status   # Check bridge status"
}

# Check interfaces
check_interfaces() {
    log "Checking network interfaces..."
    
    if ! ip link show "$WAN_INTERFACE" > /dev/null 2>&1; then
        error "WAN interface $WAN_INTERFACE not found"
        return 1
    fi
    
    if ! ip link show "$LAN_INTERFACE" > /dev/null 2>&1; then
        error "LAN interface $LAN_INTERFACE not found"
        return 1
    fi
    
    log "Both interfaces found: $WAN_INTERFACE and $LAN_INTERFACE"
}

# Install packages (skipped if already present)
install_packages() {
    if dpkg -s bridge-utils isc-dhcp-server iptables-persistent >/dev/null 2>&1; then
        log "Required packages already installed, skipping"
        return 0
    fi
    log "Installing required packages..."
    apt-get update -qq
    apt-get install -y bridge-utils net-tools ifupdown curl isc-dhcp-server iptables-persistent
}

# Enable IP forwarding
enable_ip_forwarding() {
    log "Enabling IPv4 forwarding..."
    
    sysctl -w net.ipv4.ip_forward=1
    
    if [[ -f /etc/sysctl.conf ]]; then
        if grep -q "#net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        elif ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
    elif [[ -d /etc/sysctl.d ]]; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
    else
        warn "Could not find sysctl configuration file"
    fi
    
    if [[ $(sysctl -n net.ipv4.ip_forward) == "1" ]]; then
        log "IPv4 forwarding enabled successfully"
    else
        error "Failed to enable IPv4 forwarding"
        return 1
    fi
}

# Clean up existing configuration
cleanup_bridge() {
    log "Cleaning up existing network configuration..."
    
    # Stop DHCP server
    systemctl stop isc-dhcp-server 2>/dev/null || true
    
    # Remove any existing bridge
    if ip link show "$BRIDGE_NAME" > /dev/null 2>&1; then
        log "Removing existing bridge $BRIDGE_NAME"
        ip link set "$WAN_INTERFACE" nomaster 2>/dev/null || true
        ip link set "$LAN_INTERFACE" nomaster 2>/dev/null || true
        ip link set "$BRIDGE_NAME" down 2>/dev/null || true
        ip link delete "$BRIDGE_NAME" type bridge 2>/dev/null || true
    fi
    
    # Flush interface addresses
    ip addr flush dev "$WAN_INTERFACE" 2>/dev/null || true
    ip addr flush dev "$LAN_INTERFACE" 2>/dev/null || true
    
    # Release DHCP leases
    dhcp_release "$WAN_INTERFACE"
    dhcp_release "$LAN_INTERFACE"
}

# Create bridge
create_bridge() {
    log "Creating network bridge for internet traffic flow..."
    warn "Note: Network connectivity will be temporarily disrupted"
    warn "Traffic flow: Modem -> eth0 -> eth1 -> Router"

    cleanup_bridge
    set_unmanaged_if_possible
    stop_lan_dhcp_clients
    
    # Configure eth0 for WAN (modem connection)
    log "Configuring eth0 for WAN connection to modem..."
    ip link set "$WAN_INTERFACE" down 2>/dev/null || true
    ip addr flush dev "$WAN_INTERFACE" 2>/dev/null || true
    ip link set "$WAN_INTERFACE" up
    
    # Get IP from modem via DHCP
    log "Requesting IP from modem via DHCP..."
    dhcp_request "$WAN_INTERFACE" || {
        warn "DHCP failed on $WAN_INTERFACE, setting up fallback configuration"
        ip addr add "192.168.1.2/24" dev "$WAN_INTERFACE"
    }
    
    # Configure eth1 for LAN (router connection)
    log "Configuring eth1 for LAN connection to router..."
    ip link set "$LAN_INTERFACE" down 2>/dev/null || true
    ip addr flush dev "$LAN_INTERFACE" 2>/dev/null || true
    ip link set "$LAN_INTERFACE" up
    ip addr add "$LAN_IP/24" dev "$LAN_INTERFACE"
    
    sleep 3

    # Early debug snapshot to catch immediate drops
    debug_snapshot "post-interface-config"

    log "Network interfaces configured for internet traffic flow"
    log "eth0 (WAN): Connected to modem for internet ingress"
    log "eth1 (LAN): Connected to router for internet egress"
}

# Fix DNS
fix_dns() {
    log "Fixing DNS configuration..."
    
    # Backup current resolv.conf
    cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    
    # Wait for network to stabilize after bridge setup
    sleep 5
    
    # Remove any immutable flag
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Stop conflicting DNS services first
    log "Stopping conflicting DNS services..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    sleep 2
    
    # Test current DNS with timeout
    if timeout 10 nslookup google.com >/dev/null 2>&1; then
        log "Current DNS configuration working, preserving it"
        # Start services back up
        systemctl start systemd-resolved 2>/dev/null || true
        return 0
    fi
    
    log "Setting reliable DNS servers..."
    # Create new resolv.conf with proper permissions
    cat > /etc/resolv.conf << EOF
# Generated by unified bridge setup - DNS fix
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 8.8.4.4
nameserver 1.0.0.1
# Local fallback
nameserver 192.168.1.1
EOF
    
    # Set proper permissions
    chmod 644 /etc/resolv.conf
    
    # Don't make immutable - let NetworkManager manage it
    # Instead, configure NetworkManager to use these DNS servers
    if command -v nmcli >/dev/null 2>&1; then
        log "Configuring NetworkManager DNS settings..."
        # Get the first active connection name (skip header line)
        local active_conn=$(nmcli connection show --active | grep -v "NAME" | head -1 | awk '{print $1}' | tr -d ' ')
        if [[ -n "$active_conn" && "$active_conn" != "--" ]]; then
            log "Found active connection: $active_conn"
            nmcli connection modify "$active_conn" ipv4.dns "8.8.8.8 1.1.1.1 8.8.4.4" ipv4.ignore-auto-dns yes 2>/dev/null || warn "Failed to modify NetworkManager connection"
            nmcli connection up "$active_conn" 2>/dev/null || warn "Failed to bring up NetworkManager connection"
        else
            warn "No active NetworkManager connection found - skipping NetworkManager DNS configuration"
        fi
    fi
    
    # Start DNS services one by one
    log "Starting DNS services..."
    systemctl start systemd-resolved 2>/dev/null || true
    sleep 3
    
    # Test DNS with multiple attempts
    local dns_works=false
    for attempt in {1..3}; do
        log "DNS test attempt $attempt..."
        if timeout 10 nslookup google.com >/dev/null 2>&1; then
            dns_works=true
            break
        fi
        sleep 2
    done
    
    if $dns_works; then
        log "DNS configuration successful"
        return 0
    else
        warn "DNS resolution test failed - attempting network restart"
        systemctl restart networking 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || true
        sleep 8
        
        # Test again after network restart
        if timeout 10 nslookup google.com >/dev/null 2>&1; then
            log "DNS configuration successful after network restart"
            return 0
        else
            warn "DNS still failing - adding essential services to hosts file"
            # Add critical services to hosts as backup
            cat >> /etc/hosts << EOF
# Added by bridge setup - DNS fallback
140.82.112.4 github.com
140.82.112.3 gist.github.com
140.82.112.2 api.github.com
151.101.1.194 registry.npmjs.org
104.21.3.145 docker.com
EOF
            
            # Test GitHub specifically
            if timeout 10 nslookup github.com >/dev/null 2>&1 || ping -c 1 140.82.112.4 >/dev/null 2>&1; then
                log "GitHub resolution working via hosts file"
                return 0
            else
                error "DNS resolution completely failed - manual intervention required"
                echo "Try: systemctl restart systemd-resolved && systemctl restart NetworkManager"
                echo "Or: reboot the system"
                return 1
            fi
        fi
    fi
}

# Setup iptables
setup_iptables() {
    log "Setting up iptables rules for internet traffic routing..."
    
    # Clear existing rules
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    
    # Set default policies
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    
    # Allow established connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    
    # Allow SSH
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true

    # Allow IDPS collector API (for VPS to reach Pi)
    iptables -A INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p tcp --dport 8090 -j ACCEPT 2>/dev/null || true

    # Enable NAT for traffic from eth1 to eth0 (internet sharing)
    log "Enabling NAT for internet traffic flow: eth1 -> eth0"
    iptables -t nat -A POSTROUTING -o "$WAN_INTERFACE" -j MASQUERADE 2>/dev/null || true
    
    # Allow forwarding between interfaces
    iptables -A FORWARD -i "$LAN_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i "$WAN_INTERFACE" -o "$LAN_INTERFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    
    # Save rules
    mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    
    log "iptables configured for internet traffic routing"
}

# Setup DHCP server for LAN interface
setup_dhcp_server() {
    log "Setting up DHCP server for eth1 (router connection)..."
    
    # Check if DHCP server is installed
    if ! command -v dhcpd >/dev/null 2>&1; then
        warn "DHCP server not found, installing..."
        apt-get install -y isc-dhcp-server || {
            error "Failed to install DHCP server"
            return 1
        }
    fi
    
    # Stop any existing DHCP server
    systemctl stop isc-dhcp-server 2>/dev/null || true
    killall dhcpd 2>/dev/null || true
    
    # Backup existing configuration
    if [[ -f /etc/dhcp/dhcpd.conf ]]; then
        cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.backup.$(date +%Y%m%d_%H%M%S)
    fi
    
    # Create DHCP server configuration
    cat > /etc/dhcp/dhcpd.conf << EOF
# DHCP server configuration for eth1 (router connection)
default-lease-time 600;
max-lease-time 7200;

# Use this network for eth1
subnet 192.168.100.0 netmask 255.255.255.0 {
    range 192.168.100.100 192.168.100.200;
    option routers $LAN_IP;
    option domain-name-servers 8.8.8.8, 1.1.1.1;
    option broadcast-address 192.168.100.255;
}
EOF
    
    # Configure interface for DHCP server
    cat > /etc/default/isc-dhcp-server << EOF
INTERFACESv4="$LAN_INTERFACE"
INTERFACESv6=""
EOF
    
    # Ensure the interface is up and has IP before starting DHCP
    if ! ip addr show "$LAN_INTERFACE" | grep -q "$LAN_IP"; then
        warn "LAN interface $LAN_INTERFACE doesn't have IP $LAN_IP, configuring..."
        ip addr add "$LAN_IP/24" dev "$LAN_INTERFACE" 2>/dev/null || true
    fi
    ip link set "$LAN_INTERFACE" up 2>/dev/null || true
    sleep 1

    # Ensure lease file exists (isc-dhcp-server will not start without it)
    mkdir -p /var/lib/dhcp
    touch /var/lib/dhcp/dhcpd.leases
    chmod 644 /var/lib/dhcp/dhcpd.leases

    # Test DHCP configuration syntax
    log "Testing DHCP configuration syntax..."
    if dhcpd -t -cf /etc/dhcp/dhcpd.conf >/dev/null 2>&1; then
        log "DHCP configuration syntax is valid"
    else
        error "DHCP configuration syntax error:"
        dhcpd -t -cf /etc/dhcp/dhcpd.conf
        return 1
    fi
    
    # Start DHCP server with better error handling
    log "Starting DHCP server..."
    
    # Try systemctl first
    if systemctl enable isc-dhcp-server 2>/dev/null; then
        if systemctl restart isc-dhcp-server 2>/dev/null; then
            sleep 2
            if systemctl is-active isc-dhcp-server >/dev/null 2>&1; then
                log "✓ DHCP server started successfully via systemctl"
                return 0
            fi
        fi
    fi
    
    # Fallback to manual dhcpd start
    warn "systemctl method failed, trying manual dhcpd start..."
    if dhcpd -cf /etc/dhcp/dhcpd.conf -pf /var/run/dhcpd.pid "$LAN_INTERFACE" >/dev/null 2>&1; then
        sleep 2
        if pgrep dhcpd >/dev/null; then
            log "✓ DHCP server started successfully manually"
            return 0
        fi
    fi
    
    # If all methods fail, provide troubleshooting info
    error "DHCP server failed to start"
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Check if another DHCP server is running: netstat -ulnp | grep :67"
    echo "2. Check interface status: ip addr show $LAN_INTERFACE"
    echo "3. Check DHCP logs: journalctl -u isc-dhcp-server"
    echo "4. Test config manually: dhcpd -t -cf /etc/dhcp/dhcpd.conf"
    echo "5. Check for conflicts: lsof -i :67"
    echo ""
    echo "Continuing without DHCP server - router will need static IP configuration"
    return 1
}

# Verify setup
verify_setup() {
    log "Verifying network setup for internet traffic flow..."
    
    sleep 2
    
    # Check WAN interface
    if ! ip link show "$WAN_INTERFACE" > /dev/null 2>&1; then
        error "WAN interface $WAN_INTERFACE not found"
        return 1
    fi
    
    local wan_state=$(ip link show "$WAN_INTERFACE" | grep -o "state [A-Z]*" | cut -d' ' -f2)
    if [[ "$wan_state" != "UP" ]]; then
        error "WAN interface $WAN_INTERFACE is not UP (state: $wan_state)"
        return 1
    fi
    
    # Check LAN interface
    if ! ip link show "$LAN_INTERFACE" > /dev/null 2>&1; then
        error "LAN interface $LAN_INTERFACE not found"
        return 1
    fi
    
    local lan_state=$(ip link show "$LAN_INTERFACE" | grep -o "state [A-Z]*" | cut -d' ' -f2)
    if [[ "$lan_state" != "UP" ]]; then
        error "LAN interface $LAN_INTERFACE is not UP (state: $lan_state)"
        return 1
    fi
    
    # Check IP forwarding
    if [[ $(sysctl -n net.ipv4.ip_forward) != "1" ]]; then
        warn "IP forwarding is not enabled"
    fi
    
    # Check LAN IP
    if ping -c 1 -W 2 "$LAN_IP" >/dev/null 2>&1; then
        log "LAN IP is reachable: $LAN_IP"
    else
        warn "LAN IP is not reachable: $LAN_IP"
    fi
    
    # Test internet connectivity through WAN
    log "Testing internet connectivity through eth0..."
    if timeout 10 ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log "✓ Internet connectivity working through eth0"
    else
        warn "✗ Internet connectivity failed through eth0"
    fi
    
    # Test DNS
    if timeout 10 nslookup google.com >/dev/null 2>&1; then
        log "✓ DNS resolution working"
    else
        warn "✗ DNS resolution failed"
    fi
    
    show_status
}

# Show status
show_status() {
    log "Current Network Status:"
    echo "========================"
    
    echo "WAN Interface (eth0 - to modem):"
    ip addr show "$WAN_INTERFACE" 2>/dev/null || echo "WAN interface not found"
    echo ""
    
    echo "LAN Interface (eth1 - to router):"
    ip addr show "$LAN_INTERFACE" 2>/dev/null || echo "LAN interface not found"
    echo ""
    
    echo "IP Forwarding: $(sysctl -n net.ipv4.ip_forward)"
    echo ""
    
    echo "NAT Rules:"
    iptables -t nat -L POSTROUTING -n -v 2>/dev/null || echo "No NAT rules found"
    echo ""
    
    echo "Forward Rules:"
    iptables -L FORWARD -n -v 2>/dev/null || echo "No forward rules found"
    echo ""
    
    echo "Internet Test (eth0):"
    if timeout 10 ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "✓ Internet connectivity working"
    else
        echo "✗ Internet connectivity failed"
    fi
    
    echo ""
    echo "DNS Test:"
    if timeout 10 nslookup google.com >/dev/null 2>&1; then
        echo "✓ DNS resolution working"
    else
        echo "✗ DNS resolution failed (timeout or error)"
    fi
    
    echo ""
    echo "DHCP Server Status:"
    systemctl is-active isc-dhcp-server 2>/dev/null && echo "✓ DHCP server running" || echo "✗ DHCP server not running"
}

# Troubleshoot connection issues (especially for TP-Link Deco)
troubleshoot_connection() {
    log "Troubleshooting connection issues for TP-Link Deco..."
    echo "======================================================"
    
    # Check basic network connectivity
    echo "1. Checking network interface status..."
    echo "========================================"
    
    # WAN interface (eth0) - connection to modem
    echo "WAN Interface (eth0 - to modem):"
    if ip link show "$WAN_INTERFACE" >/dev/null 2>&1; then
        local wan_state=$(ip link show "$WAN_INTERFACE" | grep -o "state [A-Z]*" | cut -d' ' -f2)
        echo "  Status: $wan_state"
        
        if [[ "$wan_state" == "UP" ]]; then
            local wan_ip=$(ip addr show "$WAN_INTERFACE" | grep "inet " | awk '{print $2}' | head -1)
            if [[ -n "$wan_ip" ]]; then
                echo "  IP Address: $wan_ip ✓"
            else
                echo "  IP Address: None ✗"
            fi
        else
            echo "  Interface is DOWN ✗"
        fi
    else
        echo "  Interface not found ✗"
    fi
    echo ""
    
    # LAN interface (eth1) - connection to Deco
    echo "LAN Interface (eth1 - to Deco):"
    if ip link show "$LAN_INTERFACE" >/dev/null 2>&1; then
        local lan_state=$(ip link show "$LAN_INTERFACE" | grep -o "state [A-Z]*" | cut -d' ' -f2)
        echo "  Status: $lan_state"
        
        if [[ "$lan_state" == "UP" ]]; then
            local lan_ip=$(ip addr show "$LAN_INTERFACE" | grep "inet " | awk '{print $2}' | head -1)
            if [[ -n "$lan_ip" ]]; then
                echo "  IP Address: $lan_ip ✓"
            else
                echo "  IP Address: None ✗"
            fi
        else
            echo "  Interface is DOWN ✗"
        fi
    else
        echo "  Interface not found ✗"
    fi
    echo ""
    
    # Test internet connectivity
    echo "2. Testing internet connectivity..."
    echo "==================================="
    
    if ping -c 3 -W 5 8.8.8.8 >/dev/null 2>&1; then
        echo "✓ Internet connectivity working"
    else
        echo "✗ Internet connectivity failed"
        echo "  This could be the reason your Deco is not green"
    fi
    
    if ping -c 3 -W 5 google.com >/dev/null 2>&1; then
        echo "✓ DNS resolution working"
    else
        echo "✗ DNS resolution failed"
    fi
    echo ""
    
    # Check DHCP server status
    echo "3. Checking DHCP server status..."
    echo "================================="
    
    if systemctl is-active isc-dhcp-server >/dev/null 2>&1; then
        echo "✓ DHCP server running via systemctl"
    elif pgrep dhcpd >/dev/null; then
        echo "✓ DHCP server running manually"
    else
        echo "✗ DHCP server not running"
        echo "  This is likely why your Deco is not getting an IP"
    fi
    
    # Check if DHCP is listening on port 67
    if netstat -ulnp 2>/dev/null | grep -q ":67"; then
        echo "✓ DHCP server listening on port 67"
    else
        echo "✗ DHCP server not listening on port 67"
    fi
    echo ""
    
    # Check for common issues
    echo "4. Common TP-Link Deco issues..."
    echo "================================="
    
    # Check if Deco is getting IP from our DHCP
    echo "Checking for DHCP leases..."
    if [[ -f /var/lib/dhcp/dhcpd.leases ]]; then
        local lease_count=$(grep -c "lease " /var/lib/dhcp/dhcpd.leases 2>/dev/null || echo "0")
        if [[ $lease_count -gt 0 ]]; then
            echo "✓ Found $lease_count DHCP lease(s)"
            echo "Recent leases:"
            tail -10 /var/lib/dhcp/dhcpd.leases | grep -A 5 "lease " | tail -6
        else
            echo "✗ No DHCP leases found"
            echo "  Deco is not getting an IP address from this Pi"
        fi
    else
        echo "✗ DHCP lease file not found"
    fi
    echo ""
    
    # Provide specific solutions
    echo "5. Solutions for TP-Link Deco..."
    echo "================================"
    
    echo "If your Deco is not turning green, try these solutions:"
    echo ""
    echo "SOLUTION 1: Restart the network setup"
    echo "  sudo $0 revert"
    echo "  sudo $0 setup"
    echo ""
    echo "SOLUTION 2: Configure Deco manually"
    echo "  1. Connect to Deco via Ethernet cable to eth1"
    echo "  2. Access Deco settings (usually 192.168.68.1)"
    echo "  3. Set Deco to Access Point mode"
    echo "  4. Configure static IP:"
    echo "     - IP: 192.168.100.2"
    echo "     - Mask: 255.255.255.0"
    echo "     - Gateway: 192.168.100.1"
    echo "     - DNS: 8.8.8.8, 1.1.1.1"
    echo ""
    echo "SOLUTION 3: Check physical connections"
    echo "  - Ensure eth1 is connected to Deco's WAN port"
    echo "  - Ensure eth0 is connected to modem"
    echo "  - Try different Ethernet cables"
    echo "  - Power cycle Deco (unplug for 30 seconds)"
    echo ""
    echo "SOLUTION 4: Reset Deco to factory settings"
    echo "  - Press reset button for 10 seconds"
    echo "  - Set up again using Deco app"
    echo "  - Choose 'Wired connection' option"
    echo ""
    
    # Show current network status
    echo ""
    echo "Current Network Status:"
    echo "======================"
    show_status
}

# Complete revert
complete_revert() {
    log "Reverting all bridge configuration..."
    
    cleanup_bridge
    
    ip addr flush dev "$WAN_INTERFACE" 2>/dev/null || true
    ip addr flush dev "$LAN_INTERFACE" 2>/dev/null || true
    
    ip link set "$WAN_INTERFACE" down 2>/dev/null || true
    ip link set "$LAN_INTERFACE" down 2>/dev/null || true
    sleep 2
    ip link set "$WAN_INTERFACE" up 2>/dev/null || true
    ip link set "$LAN_INTERFACE" up 2>/dev/null || true
    
    sysctl -w net.ipv4.ip_forward=0
    sed -i 's/net.ipv4.ip_forward=1/#net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null || true
    rm -f /etc/sysctl.d/99-ipforward.conf 2>/dev/null || true
    
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    
    systemctl stop docker 2>/dev/null || true
    docker kill $(docker ps -q) 2>/dev/null || true
    
    systemctl restart networking 2>/dev/null || true
    systemctl restart NetworkManager 2>/dev/null || true
    systemctl restart systemd-networkd 2>/dev/null || true
    
    sleep 5
    
    dhcp_release
    dhcp_request "$WAN_INTERFACE" 2>/dev/null || true
    
    rm -f /etc/resolv.conf.backup.* 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
    
    log "Revert completed - system restored to default"
}

# Setup network routing
setup_bridge() {
    log "Starting Raspberry Pi Network Routing Setup for IDPS"
    echo "==================================================="
    echo "WAN Interface: $WAN_INTERFACE (to modem for internet ingress)"
    echo "LAN Interface: $LAN_INTERFACE (to router for internet egress)"
    echo "LAN IP: $LAN_IP"
    echo "DHCP Range: $DHCP_RANGE"
    echo "==================================================="
    
    check_interfaces
    set_unmanaged_if_possible
    stop_lan_dhcp_clients
    start_link_monitor
    install_packages
    enable_ip_forwarding
    create_bridge
    setup_iptables
    
    # Try to setup DHCP server, but continue if it fails
    if setup_dhcp_server; then
        log "DHCP server configured successfully"
    else
        warn "DHCP server setup failed - providing manual configuration instructions"
        echo ""
        echo "Manual Router Configuration Required:"
        echo "===================================="
        echo "Configure your router with the following static settings:"
        echo "- IP Address: 192.168.100.2"
        echo "- Subnet Mask: 255.255.255.0"
        echo "- Gateway: 192.168.100.1 (this Pi)"
        echo "- DNS Servers: 8.8.8.8, 1.1.1.1"
        echo ""
        echo "Or configure the router to use DHCP from this Pi (if DHCP is working)"
        echo ""
    fi
    
    fix_dns
    verify_setup

    # Final snapshot after setup
    debug_snapshot "post-setup"
    stop_link_monitor
    
    echo ""
    log "Network routing setup completed!"
    warn "Internet traffic flow: Modem -> eth0 -> eth1 -> Router"
    
    if ! systemctl is-active isc-dhcp-server >/dev/null 2>&1 && ! pgrep dhcpd >/dev/null; then
        warn "Note: DHCP server is not running - manual router configuration required"
    else
        log "DHCP server is running - router should get IP automatically"
    fi
    
    echo ""
    log "Starting IDPS Docker services..."
    local compose_dir started=false
    for compose_dir in "$(dirname "$0")/../.." "/home/pi/idps" "/opt/idps"; do
        if [[ -f "$compose_dir/docker-compose.raspi.yml" ]]; then
            log "Found docker-compose.raspi.yml at $compose_dir"
            docker-compose -f "$compose_dir/docker-compose.raspi.yml" up -d \
                && log "✓ IDPS Docker services started" \
                || warn "Docker services failed — run manually: docker-compose -f docker-compose.raspi.yml up -d"
            started=true
            break
        fi
    done
    [[ "$started" == false ]] && warn "docker-compose.raspi.yml not found — skipping Docker startup"

    log "To revert changes: $0 revert"
    log "To check status:   $0 status"
}

# Main execution
main() {
    check_root
    init_logging
    trap stop_link_monitor EXIT
    
    case "${1:-setup}" in
        "setup")
            setup_bridge
            ;;
        "revert")
            complete_revert
            ;;
        "status")
            show_status
            ;;
        "fix-dns")
            fix_dns
            ;;
        "troubleshoot")
            troubleshoot_connection
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            error "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
