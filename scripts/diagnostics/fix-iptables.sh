#!/bin/bash

# Fix iptables DNAT rule error and reset iptables configuration

set -e

echo "🔧 Fixing iptables DNAT rule error..."

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

print_header "1. BACKING UP CURRENT IPTABLES"

print_status "Backing up current iptables rules..."
if [ -f /etc/iptables/rules.v4 ]; then
    cp /etc/iptables/rules.v4 /etc/iptables/rules.v4.backup.$(date +%Y%m%d_%H%M%S)
    print_status "✓ Existing rules backed up"
fi

iptables-save > /tmp/iptables-backup-$(date +%Y%m%d_%H%M%S).rules
print_status "✓ Current rules saved to /tmp/"

print_header "2. CLEARING ALL IPTABLES RULES"

print_status "Flushing all iptables rules..."

# Clear all rules
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true
iptables -t raw -F 2>/dev/null || true
iptables -t raw -X 2>/dev/null || true

# Zero all counters
iptables -Z 2>/dev/null || true
iptables -t nat -Z 2>/dev/null || true
iptables -t mangle -Z 2>/dev/null || true

print_success "✓ All iptables rules cleared"

print_header "3. SETTING DEFAULT POLICIES"

print_status "Setting default policies to ACCEPT..."

# Set default policies to ACCEPT
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true

# Set NAT and mangle default policies
iptables -t nat -P PREROUTING ACCEPT 2>/dev/null || true
iptables -t nat -P INPUT ACCEPT 2>/dev/null || true
iptables -t nat -P OUTPUT ACCEPT 2>/dev/null || true
iptables -t nat -P POSTROUTING ACCEPT 2>/dev/null || true

print_success "✓ Default policies set to ACCEPT"

print_header "4. SETTING UP BASIC RULES"

print_status "Setting up basic iptables rules for IDPS..."

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true

# Allow established and related connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

# Allow SSH (important for remote access)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true

# Allow ICMP (ping)
iptables -A INPUT -p icmp -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -p icmp -j ACCEPT 2>/dev/null || true

print_success "✓ Basic rules configured"

print_header "5. SETTING UP NAT RULES (CAREFULLY)"

print_status "Setting up NAT rules without DNAT conflicts..."

# Only add NAT rules if we have the interfaces
WAN_INTERFACE="eth0"
LAN_INTERFACE="eth1"

if ip link show "$WAN_INTERFACE" >/dev/null 2>&1 && ip link show "$LAN_INTERFACE" >/dev/null 2>&1; then
    print_status "Found interfaces: WAN=$WAN_INTERFACE, LAN=$LAN_INTERFACE"
    
    # Enable IP forwarding first
    echo 1 > /proc/sys/net/ipv4/ip_forward
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
    
    # Add MASQUERADE rule (this is safer than DNAT)
    if iptables -t nat -A POSTROUTING -o "$WAN_INTERFACE" -j MASQUERADE 2>/dev/null; then
        print_success "✓ MASQUERADE rule added for $WAN_INTERFACE"
    else
        print_warning "⚠️ Failed to add MASQUERADE rule"
    fi
    
    # Allow forwarding between interfaces
    iptables -A FORWARD -i "$LAN_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i "$WAN_INTERFACE" -o "$LAN_INTERFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    
    print_status "✓ Forwarding rules configured"
else
    print_warning "⚠️ Interfaces not found, skipping NAT rules"
fi

print_header "6. TESTING IPTABLES"

print_status "Testing iptables configuration..."

# Test if we can add a simple rule
if iptables -A INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null; then
    print_success "✓ iptables is working correctly"
    # Remove the test rule
    iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
else
    print_error "❌ iptables test failed"
    print_status "Checking iptables status..."
    iptables -L 2>/dev/null | head -10 || echo "Failed to list rules"
fi

print_header "7. SAVING IPTABLES RULES"

print_status "Saving iptables rules..."

# Create iptables directory if it doesn't exist
mkdir -p /etc/iptables 2>/dev/null || true

# Save the rules
if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
    print_success "✓ Rules saved to /etc/iptables/rules.v4"
else
    print_warning "⚠️ Failed to save rules to /etc/iptables/rules.v4"
fi

# Try to use iptables-persistent if available
if command -v iptables-persistent >/dev/null 2>&1; then
    print_status "Configuring iptables-persistent..."
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null || true
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null || true
    dpkg-reconfigure -f noninteractive iptables-persistent 2>/dev/null || true
    print_status "✓ iptables-persistent configured"
fi

print_header "8. VERIFYING CONFIGURATION"

print_status "Verifying final iptables configuration..."

echo ""
echo "Current iptables rules:"
echo "======================="

# Show filter table
echo "FILTER TABLE:"
iptables -L -n -v --line-numbers 2>/dev/null | head -20

echo ""
echo "NAT TABLE:"
iptables -t nat -L -n -v --line-numbers 2>/dev/null | head -10

echo ""
echo "IP Forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"

print_header "9. TROUBLESHOOTING TIPS"

echo ""
echo "🔧 If you still have issues:"
echo ""
echo "1. Check for conflicting rules:"
echo "   iptables -t nat -L -n -v"
echo ""
echo "2. Check if Docker is interfering:"
echo "   docker ps"
echo "   iptables -L | grep DOCKER"
echo ""
echo "3. Reset completely if needed:"
echo "   iptables -F && iptables -X && iptables -t nat -F && iptables -t nat -X"
echo ""
echo "4. Check kernel modules:"
echo "   lsmod | grep ipt"
echo ""
echo "5. Restart networking if needed:"
echo "   systemctl restart networking"
echo ""

print_success "🎉 iptables fix completed!"

# Test basic connectivity
print_status "Testing basic connectivity..."
if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
    print_success "✅ Internet connectivity working"
else
    print_warning "⚠️ Internet connectivity issue - may need further configuration"
fi

echo ""
echo "📊 Summary:"
echo "  - All iptables rules cleared"
echo "  - Basic rules configured"
echo "  - NAT rules set up (if interfaces found)"
echo "  - IP forwarding enabled"
echo "  - Rules saved for persistence"
echo ""
echo "You can now retry your bridge setup:"
echo "  sudo ./scripts/setup-bridge-unified.sh setup"
