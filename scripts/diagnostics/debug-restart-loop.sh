#!/bin/bash

# Debug script for Suricata and Packet Processor restart loop

set -e

echo "🔍 Debugging Suricata and Packet Processor restart loop..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

cd /home/brent/idps

print_header "1. CHECKING CONTAINER STATUS"

echo "Current container status:"
docker ps -a | grep -E "(suricata|packet-processor)"

print_header "2. CHECKING RECENT LOGS"

echo "=== Suricata Logs (last 30 lines) ==="
docker logs idps-suricata-pi --tail 30 2>&1 || echo "Suricata container not found"

echo ""
echo "=== Packet Processor Logs (last 30 lines) ==="
docker logs idps-packet-processor --tail 30 2>&1 || echo "Packet processor container not found"

print_header "3. CHECKING COMMON ISSUES"

# Check if required directories exist
print_status "Checking required directories..."
if [ ! -d "data/logs/suricata" ]; then
    print_warning "data/logs/suricata directory missing"
else
    print_status "✅ data/logs/suricata exists"
fi

if [ ! -d "data/suricata/rules" ]; then
    print_warning "data/suricata/rules directory missing"
else
    print_status "✅ data/suricata/rules exists"
fi

# Check if rules file exists
if [ ! -f "config/suricata/rules/idps-dynamic.rules" ]; then
    print_warning "idps-dynamic.rules missing"
else
    print_status "✅ idps-dynamic.rules exists"
fi

# Check network interfaces
print_status "Checking network interfaces..."
ip addr show | grep -E "^[0-9]+:" | awk '{print "  " $2}' | sed 's/:$//'

# Check bridge interface br0
if ip addr show br0 >/dev/null 2>&1; then
    print_status "✅ br0 interface exists"
else
    print_warning "⚠️ br0 interface does not exist"
    print_status "Available interfaces:"
    ip addr show | grep -E "^[0-9]+:" | awk '{print "  " $2}' | sed 's/:$//'
fi

print_header "4. CHECKING DOCKER COMPOSE CONFIGURATION"

echo "Checking Suricata configuration in docker-compose.raspi.yml..."
grep -A 20 -B 5 "suricata:" docker-compose.raspi.yml | head -30

echo ""
echo "Checking packet-processor configuration..."
grep -A 15 -B 5 "packet-processor:" docker-compose.raspi.yml | head -25

print_header "5. CHECKING SYSTEM RESOURCES"

echo "Memory usage:"
free -h

echo ""
echo "Disk usage:"
df -h | head -5

echo ""
echo "Docker system info:"
docker system df

print_header "6. STOPPING CONTAINERS AND CLEANING UP"

print_status "Stopping all containers..."
docker compose -f docker-compose.raspi.yml down || true

print_status "Removing orphaned containers..."
docker container prune -f

print_status "Cleaning up unused images..."
docker image prune -f

print_header "7. FIXING COMMON CONFIGURATION ISSUES"

# Fix 1: Ensure proper interface configuration
print_status "Checking interface configuration..."
CURRENT_INTERFACE=$(grep "SURICATA_IFACE" docker-compose.raspi.yml | head -1 | cut -d'=' -f2)
echo "Current interface: $CURRENT_INTERFACE"

if ! ip addr show "$CURRENT_INTERFACE" >/dev/null 2>&1; then
    print_warning "Interface $CURRENT_INTERFACE does not exist"
    print_status "Switching to eth0..."
    sed -i "s/SURICATA_IFACE=.*/SURICATA_IFACE=eth0/" docker-compose.raspi.yml
    sed -i "s/-i $CURRENT_INTERFACE/-i eth0/" docker-compose.raspi.yml
    sed -i "s/CAPTURE_INTERFACE=.*/CAPTURE_INTERFACE=eth0/" docker-compose.raspi.yml
fi

# Fix 2: Ensure proper volume mappings
print_status "Checking volume mappings..."
if ! grep -q "./data/logs/suricata:/var/log/suricata" docker-compose.raspi.yml; then
    print_warning "Suricata log volume mapping missing"
    print_status "Adding volume mapping..."
    # This would need manual editing
fi

# Fix 3: Create missing directories
print_status "Ensuring directories exist..."
mkdir -p data/logs/suricata
mkdir -p data/suricata/rules
mkdir -p data/mongodb
mkdir -p data/redis

# Fix 4: Set proper permissions
print_status "Setting proper permissions..."
chmod 755 data/logs/suricata
chmod 755 data/suricata/rules

print_header "8. RESTARTING SERVICES STEP BY STEP"

print_status "Starting core services first..."
docker compose -f docker-compose.raspi.yml up -d mongodb redis

print_status "Waiting for core services..."
sleep 10

print_status "Starting Suricata..."
docker compose -f docker-compose.raspi.yml up -d suricata

print_status "Waiting for Suricata..."
sleep 15

# Check if Suricata is stable
if docker ps | grep -q "idps-suricata-pi.*Up"; then
    print_status "✅ Suricata is running"
    sleep 10
    
    # Check again to see if it's still running
    if docker ps | grep -q "idps-suricata-pi.*Up"; then
        print_status "✅ Suricata appears stable"
        
        print_status "Starting packet processor..."
        docker compose -f docker-compose.raspi.yml up -d packet-processor
        
        sleep 10
        
        if docker ps | grep -q "idps-packet-processor.*Up"; then
            print_status "✅ Packet processor is running"
        else
            print_error "❌ Packet processor failed to start"
            docker logs idps-packet-processor --tail 20
        fi
    else
        print_error "❌ Suricata crashed after startup"
        docker logs idps-suricata-pi --tail 30
    fi
else
    print_error "❌ Suricata failed to start"
    docker logs idps-suricata-pi --tail 30
fi

print_header "9. FINAL STATUS CHECK"

echo "Final container status:"
docker ps | grep -E "(suricata|packet-processor)"

echo ""
echo "Checking if eve.json is being generated..."
if [ -f "data/logs/suricata/eve.json" ]; then
    LINE_COUNT=$(wc -l < data/logs/suricata/eve.json 2>/dev/null || echo "0")
    echo "✅ eve.json exists with $LINE_COUNT lines"
else
    echo "❌ eve.json not found"
fi

print_header "10. TROUBLESHOOTING RECOMMENDATIONS"

echo "If containers are still restarting:"
echo "1. Check Docker logs: docker logs <container-name>"
echo "2. Check system resources: free -h && df -h"
echo "3. Verify network interface: ip addr show"
echo "4. Check configuration files: cat docker-compose.raspi.yml"
echo "5. Try manual Suricata: docker run --rm --privileged jasonish/suricata:latest suricata --version"
echo ""
echo "Common fixes:"
echo "- Ensure br0 interface exists or use eth0"
echo "- Check disk space and memory"
echo "- Verify volume mappings are correct"
echo "- Make sure rules files exist and are valid"

print_status "Debug script completed!"
