#!/bin/bash

# IDPS Suricata Diagnostic and Fix Script
# Comprehensive check and fix for Suricata traffic capture issues

set -e

echo "🔍 IDPS Suricata Diagnostic and Fix Script..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

cd /home/brent/idps

print_header "1. CHECKING CONTAINER STATUS"
print_status "Checking if Suricata container is running..."
if docker ps | grep -q "idps-suricata-pi"; then
    print_status "✅ Suricata container is running"
    docker ps | grep suricata
else
    print_error "❌ Suricata container is not running"
    print_status "Attempting to start Suricata..."
    docker compose -f docker-compose.raspi.yml up -d suricata
    sleep 5
fi

print_header "2. CHECKING SURICATA LOGS"
print_status "Checking Suricata container logs..."
echo "=== Recent Suricata Logs ==="
docker logs idps-suricata-pi --tail 20

print_header "3. CHECKING BRIDGE CONFIGURATION"
print_status "Checking bridge interface..."
if ip addr show br0 >/dev/null 2>&1; then
    print_status "✅ Bridge br0 exists"
    echo "Bridge details:"
    ip addr show br0
    echo ""
    echo "Bridge table:"
    brctl show
else
    print_error "❌ Bridge br0 does not exist"
    print_status "Creating bridge..."
    ip link set br0 down 2>/dev/null || true
    brctl delbr br0 2>/dev/null || true
    brctl addbr br0
    ip link set br0 up
    brctl addif br0 eth0
    brctl addif br0 eth1
    ip link set eth0 up
    ip link set eth1 up
    print_status "✅ Bridge created and configured"
fi

print_header "4. CHECKING TRAFFIC ON BRIDGE"
print_status "Testing traffic capture on bridge..."
if timeout 10 tcpdump -i br0 -c 3 2>/dev/null | grep -q "."; then
    print_status "✅ Bridge is capturing traffic"
else
    print_warning "⚠️ No immediate traffic captured, generating test traffic..."
    ping -c 3 8.8.8.8 >/dev/null 2>&1 &
    curl -s http://example.com >/dev/null 2>&1 &
    sleep 3
    if timeout 10 tcpdump -i br0 -c 3 2>/dev/null | grep -q "."; then
        print_status "✅ Bridge is now capturing traffic"
    else
        print_warning "⚠️ Still no traffic on bridge"
    fi
fi

print_header "5. CHECKING LOG DIRECTORY AND PERMISSIONS"
print_status "Checking log directory structure..."
mkdir -p /home/brent/idps/data/logs/suricata
chmod 755 /home/brent/idps/data/logs/suricata
chown root:root /home/brent/idps/data/logs/suricata

echo "Directory permissions:"
ls -la /home/brent/idps/data/logs/suricata/

print_header "6. CHECKING SURICATA CONFIGURATION"
print_status "Checking eve.json output configuration..."
echo "=== Eve-log configuration ==="
docker exec idps-suricata-pi cat /etc/suricata/suricata.yaml | grep -A 15 -B 5 "eve-log" || echo "Eve-log config not found"

print_header "7. TESTING SURICATA CONFIGURATION"
print_status "Testing Suricata configuration syntax..."
if docker exec idps-suricata-pi suricata -c /etc/suricata/suricata.yaml -T >/dev/null 2>&1; then
    print_status "✅ Suricata configuration is valid"
else
    print_error "❌ Suricata configuration has errors"
    docker exec idps-suricata-pi suricata -c /etc/suricata/suricata.yaml -T
fi

print_header "8. CHECKING FOR EVE.JSON FILE"
print_status "Checking if eve.json exists..."
if [ -f /home/brent/idps/data/logs/suricata/eve.json ]; then
    print_status "✅ eve.json file exists"
    echo "File size: $(du -h /home/brent/idps/data/logs/suricata/eve.json | cut -f1)"
    echo "Last modified: $(stat -c %y /home/brent/idps/data/logs/suricata/eve.json)"
    echo "=== Latest events ==="
    tail -5 /home/brent/idps/data/logs/suricata/eve.json
else
    print_warning "⚠️ eve.json file not found"
fi

print_header "9. ALTERNATIVE: TRY ETH0 DIRECTLY"
print_status "Trying Suricata on eth0 interface as fallback..."
print_status "Stopping current Suricata..."
docker compose -f docker-compose.raspi.yml stop suricata

print_status "Updating configuration to use eth0..."
cp docker-compose.raspi.yml docker-compose.raspi.yml.backup
sed -i 's/SURICATA_IFACE=br0/SURICATA_IFACE=eth0/' docker-compose.raspi.yml
sed -i 's/-i br0/-i eth0/' docker-compose.raspi.yml

print_status "Starting Suricata on eth0..."
docker compose -f docker-compose.raspi.yml up -d suricata
sleep 10

print_status "Checking if eve.json is created on eth0..."
if [ -f /home/brent/idps/data/logs/suricata/eve.json ]; then
    print_status "✅ eve.json created with eth0!"
    tail -5 /home/brent/idps/data/logs/suricata/eve.json
else
    print_warning "⚠️ Still no eve.json with eth0"
fi

print_header "10. GENERATING TEST TRAFFIC"
print_status "Generating various types of test traffic..."
ping -c 5 8.8.8.8 >/dev/null 2>&1 &
curl -s http://httpbin.org/ip >/dev/null 2>&1 &
nslookup google.com >/dev/null 2>&1 &
sleep 5

print_status "Checking for new logs..."
if [ -f /home/brent/idps/data/logs/suricata/eve.json ]; then
    print_status "✅ eve.json found after traffic generation!"
    echo "=== Latest events ==="
    tail -10 /home/brent/idps/data/logs/suricata/eve.json
else
    print_error "❌ Still no eve.json file"
fi

print_header "11. FINAL STATUS CHECK"
print_status "Final container status:"
docker ps | grep suricata

print_status "Final bridge status:"
brctl show 2>/dev/null || echo "No bridge configured"

print_status "Final log directory:"
ls -la /home/brent/idps/data/logs/suricata/

print_header "12. MONITORING COMMANDS"
echo "📊 Use these commands to monitor:"
echo "  - Suricata logs: docker logs idps-suricata-pi -f"
echo "  - eve.json logs: tail -f /home/brent/idps/data/logs/suricata/eve.json"
echo "  - Bridge traffic: sudo tcpdump -i br0 -c 10"
echo "  - Container status: docker ps | grep suricata"

print_header "SUMMARY"
if [ -f /home/brent/idps/data/logs/suricata/eve.json ]; then
    print_status "🎉 SUCCESS: Suricata is generating logs!"
    echo "Your IDPS system is now operational."
else
    print_error "❌ ISSUE: Suricata is still not generating logs"
    echo "Check the Suricata logs above for specific errors."
    echo "You may need to:"
    echo "  1. Verify network interface configuration"
    echo "  2. Check Suricata rule files"
    echo "  3. Ensure proper traffic flow through monitored interface"
fi

print_status "Diagnostic script completed!"
