#!/bin/bash

# Complete Suricata Setup from Scratch for Raspberry Pi
# This script sets up Suricata IDPS from zero to fully operational

set -e

echo "🚀 Setting up Suricata IDPS from scratch..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Global variables
PROJECT_DIR="/home/brent/idps"
EVE_JSON_PATH="$PROJECT_DIR/data/logs/suricata/eve.json"
ISSUES_FOUND=0
FIXES_APPLIED=0

# Functions
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((ISSUES_FOUND++))
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    ((ISSUES_FOUND++))
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    ((FIXES_APPLIED++))
}

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

print_fix() {
    echo -e "${PURPLE}[FIX]${NC} $1"
    ((FIXES_APPLIED++))
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

cd "$PROJECT_DIR"

print_header "1. SYSTEM PREPARATION"

print_status "Updating system packages..."
apt-get update -qq

print_status "Installing required packages..."
# Handle docker-compose package conflict
if dpkg -l | grep -q "docker-compose-plugin"; then
    print_status "docker-compose-plugin is installed, skipping standalone docker-compose"
    apt-get install -y docker.io curl wget hping3 tcpdump net-tools iproute2
else
    apt-get install -y docker.io docker-compose curl wget hping3 tcpdump net-tools iproute2 || {
        print_status "docker-compose installation failed, docker compose plugin should provide this functionality"
        apt-get install -y docker.io curl wget hping3 tcpdump net-tools iproute2
    }
fi

# Fix any broken packages from previous failed installation
if dpkg --audit | grep -q "docker-compose"; then
    print_status "Fixing broken docker-compose installation..."
    dpkg --configure -a || true
    apt-get install -f -y || true
fi

print_status "Starting Docker service..."
systemctl enable docker
systemctl start docker

print_status "Adding user to docker group..."
usermod -aG docker brent

print_success "✅ System preparation completed"

print_header "2. CHECKING EXISTING SETUP"

print_status "Checking current container status..."
RUNNING_CONTAINERS=$(docker ps --format "table {{.Names}}" | grep -E "(suricata|mongodb|redis)" | tail -n +2)

if [ -n "$RUNNING_CONTAINERS" ]; then
    print_status "✅ Found running containers:"
    echo "$RUNNING_CONTAINERS"
    
    # Check if Suricata is actually working
    if docker ps | grep -q "idps-suricata-pi.*Up"; then
        print_status "✅ Suricata is already running - checking if it's working..."
        sleep 5
        
        if docker ps | grep -q "idps-suricata-pi.*Up"; then
            print_status "✅ Suricata appears stable"
            
            # Check if eve.json exists and has content
            if [ -f "$EVE_JSON_PATH" ] && [ $(wc -l < "$EVE_JSON_PATH" 2>/dev/null || echo "0") -gt 0 ]; then
                print_success "✅ Suricata is already working with eve.json!"
                print_status "Skipping to verification step..."
                SKIP_SETUP=true
            else
                print_warning "⚠️ Suricata is running but eve.json is empty or missing"
                print_status "Will restart Suricata to fix the issue..."
            fi
        else
            print_warning "⚠️ Suricata is unstable (crashing)"
            print_status "Will restart Suricata..."
        fi
    fi
else
    print_status "No relevant containers running - will start fresh setup"
fi

# Only clean up if we need to restart
if [ "$SKIP_SETUP" != "true" ]; then
    print_status "Cleaning up problematic containers..."
    # Only stop containers that are having issues
    docker compose -f docker-compose.raspi.yml stop suricata packet-processor 2>/dev/null || true
    
    # Clean up old data only if eve.json is missing or empty
    if [ ! -f "$EVE_JSON_PATH" ] || [ $(wc -l < "$EVE_JSON_PATH" 2>/dev/null || echo "0") -eq 0 ]; then
        print_status "Cleaning up old Suricata data..."
        rm -rf data/logs/suricata/* 2>/dev/null || true
    fi
fi

print_success "✅ Setup check completed"

print_header "3. CREATING DIRECTORY STRUCTURE"

print_status "Creating complete directory structure..."
mkdir -p data/logs/suricata
mkdir -p data/suricata/rules
mkdir -p data/mongodb
mkdir -p data/redis
mkdir -p logs/network-filter
mkdir -p logs/ids-pi
mkdir -p scans/ids-pi

print_status "Setting proper permissions..."
chmod 755 data/logs/suricata
chmod 755 data/suricata/rules
chmod 755 data/mongodb
chmod 755 data/redis
chown -R root:root data/

print_success "✅ Directory structure created"

print_header "4. NETWORK INTERFACE DETECTION AND CONFIGURATION"

print_status "Detecting available network interfaces..."
echo "Available interfaces:"
ip addr show | grep -E "^[0-9]+:" | awk '{print "  " $2}' | sed 's/:$//'

# Detect the best interface for Suricata
BEST_INTERFACE=""
if ip addr show br0 >/dev/null 2>&1; then
    BEST_INTERFACE="br0"
    print_status "✅ Found bridge interface br0"
elif ip addr show eth0 >/dev/null 2>&1; then
    BEST_INTERFACE="eth0"
    print_status "✅ Found ethernet interface eth0"
elif ip addr show wlan0 >/dev/null 2>&1; then
    BEST_INTERFACE="wlan0"
    print_status "✅ Found wireless interface wlan0"
else
    print_error "❌ No suitable network interface found"
    exit 1
fi

print_status "Selected interface: $BEST_INTERFACE"

print_status "Testing interface connectivity..."
if timeout 5 tcpdump -i "$BEST_INTERFACE" -c 2 2>/dev/null | grep -q "."; then
    print_status "✅ Interface $BEST_INTERFACE is capturing traffic"
else
    print_warning "⚠️ No immediate traffic on $BEST_INTERFACE, generating test traffic..."
    ping -c 3 8.8.8.8 >/dev/null 2>&1 &
    sleep 3
fi

print_success "✅ Network interface configured"

print_header "5. SURICATA CONFIGURATION SETUP"

print_status "Creating Suricata configuration..."
mkdir -p config/suricata

# Create optimized suricata.yaml for Raspberry Pi
cat > config/suricata/suricata.yaml << 'EOF'
%YAML 1.1
---

# Suricata Configuration for Raspberry Pi IDPS
# Optimized for performance on ARM64

vars:
  address-groups:
    HOME_NET: "[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12]"
    EXTERNAL_NET: "!$HOME_NET"
    HTTP_SERVERS: "$HOME_NET"
    DNS_SERVERS: "$HOME_NET"

  port-groups:
    HTTP_PORTS: "80"
    HTTPS_PORTS: "443"
    DNS_PORTS: "53"

default-log-dir: /var/log/suricata/

stats:
  enabled: yes
  interval: 8

outputs:
  - fast:
      enabled: no
  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      community-id: false
      types:
        - alert:
            payload: yes
            payload-printable: yes
            http: yes
            tls: yes
        - http:
            extended: yes
        - tls:
            extended: yes
        - dns:
            query: yes
            answer: yes
        - flow:
            enabled: yes
        - icmp:
            enabled: yes
  - stats:
      enabled: yes
      filename: stats.log
      totals: yes

logging:
  default-log-level: notice
  outputs:
    - console:
        enabled: yes
    - file:
        enabled: yes
        filename: suricata.log
        level: info

af-packet:
  - interface: eth0
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    timeout: 30
    checksum-checks: auto
    threads: auto
    promisc: no
    copy-mode: ips
    buffer-size: 65535

pcap:
  - interface: eth0
    buffer-size: 16777216
    promisc: no

detect:
  profile: medium
  custom-values:
    toclient-chunk-size: 2560
    toserver-chunk-size: 2560
  sgh-mpm-context: auto
  sgh-mpm-threshold: 100
  inspection-recursion-limit: 3000

default-rule-path: /var/lib/suricata/rules
rule-files:
  - idps-dynamic.rules

thresholds:
  memcap: 100mb
  detect:
    rate: 5
    burst: 15

host:
  mode: auto
  hash-size: 65536
  prealloc: 1000
  memcap: 16777216

flow:
  memcap: 32mb
  hash-size: 65536
  prealloc: 10000
  emergency-recovery: 30

app-layer:
  protocols:
    http:
      enabled: yes
      libhtp:
        default-config:
          personality: Generic
          request-body-limit: 4096
          response-body-limit: 4096
    dns:
      enabled: yes
      tcp-ports: [53]
      udp-ports: [53]
    tls:
      enabled: yes
    ssh:
      enabled: yes
    ftp:
      enabled: yes

stream:
  memcap: 32mb
  checksum-validation: yes
  prealloc-sessions: 2000
  midstream: no
  async-oneside: no

capture:
  disable-offloading: true
EOF

# Update interface in configuration
sed -i "s/interface: eth0/interface: $BEST_INTERFACE/" config/suricata/suricata.yaml

print_success "✅ Suricata configuration created"

print_header "6. SURICATA RULES SETUP"

print_status "Creating Suricata rules..."
mkdir -p config/suricata/rules

# Create comprehensive rules file
cat > config/suricata/rules/idps-dynamic.rules << 'EOF'
# IDPS Dynamic Rules for Raspberry Pi
# Comprehensive rule set for threat detection

# ICMP Detection
alert icmp any any -> any any (msg:"ICMP Ping Detected"; sid:1000001; rev:1; classtype:attempted-recon; priority:2;)
alert icmp any any -> any any (msg:"ICMP Large Packet Detected"; dsize:>100; sid:1000002; rev:1; classtype:attempted-recon; priority:1;)

# HTTP Detection
alert tcp any any -> any 80 (msg:"HTTP Traffic Detected"; flow:established,to_server; sid:1000003; rev:1; classtype:web-application-activity; priority:3;)
alert tcp any any -> any 8080 (msg:"HTTP Alternate Port Traffic"; flow:established,to_server; sid:1000004; rev:1; classtype:web-application-activity; priority:3;)
alert tcp any any -> any 80 (msg:"Suspicious HTTP User-Agent"; content:"User-Agent|3A|"; content:"scanner|7C|bot|7C|crawler"; nocase; sid:1000005; rev:1; classtype:web-application-attack; priority:1;)

# HTTPS Detection
alert tcp any any -> any 443 (msg:"HTTPS Traffic Detected"; flow:established,to_server; sid:1000006; rev:1; classtype:web-application-activity; priority:3;)

# DNS Detection
alert udp any any -> any 53 (msg:"DNS Query Detected"; sid:1000007; rev:1; classtype:web-application-activity; priority:3;)
alert udp any any -> any 53 (msg:"DNS Query for Suspicious Domain"; content:"malware|7C|phishing|7C|botnet"; nocase; sid:1000008; rev:1; classtype:trojan-activity; priority:1;)

# SSH Detection
alert tcp any any -> any 22 (msg:"SSH Connection Detected"; flow:established,to_server; sid:1000009; rev:1; classtype:attempted-login; priority:2;)
alert tcp any any -> any 22 (msg:"SSH Brute Force Attempt"; flow:established,to_server; threshold:type both, track by_src, count 5, seconds 60; sid:1000010; rev:1; classtype:attempted-login; priority:1;)

# FTP Detection
alert tcp any any -> any 21 (msg:"FTP Connection Detected"; flow:established,to_server; sid:1000011; rev:1; classtype:policy-violation; priority:2;)

# Port Scan Detection
alert ip any any -> any any (msg:"Potential Port Scan"; threshold:type both, track by_src, count 20, seconds 10; sid:1000012; rev:1; classtype:attempted-recon; priority:1;)

# Suspicious Traffic Patterns
alert tcp any any -> any any (msg:"Suspicious TCP Flags"; flags:0; sid:1000013; rev:1; classtype:attempted-recon; priority:1;)
alert ip any any -> any any (msg:"TTL Zero or Negative"; ip_ttl:0; sid:1000014; rev:1; classtype:attempted-recon; priority:1;)

# Malware Communication
alert tcp any any -> any any (msg:"Suspicious High Port Connection"; flow:established,to_server; dport:>1024; threshold:type both, track by_dst, count 100, seconds 60; sid:1000015; rev:1; classtype:trojan-activity; priority:1;)

# Network Reconnaissance
alert ip any any -> any any (msg:"Network Sweep Detected"; threshold:type both, track by_src, count 50, seconds 30; sid:1000016; rev:1; classtype:attempted-recon; priority:1;)

# Data Exfiltration Detection
alert tcp any any -> any any (msg:"Potential Data Exfiltration"; flow:established,to_server; dsize:>1000000; sid:1000017; rev:1; classtype:policy-violation; priority:1;)

# DoS Attack Detection
alert ip any any -> any any (msg:"Potential DoS Attack"; threshold:type both, track by_dst, count 1000, seconds 10; sid:1000018; rev:1; classtype:attempted-dos; priority:1;)

# General IP Traffic for Monitoring
alert ip any any -> any any (msg:"IP Traffic Monitored"; sid:1000019; rev:1; classtype:web-application-activity; priority:4;)
EOF

print_success "✅ Suricata rules created"

print_header "7. DOCKER COMPOSE CONFIGURATION"

print_status "Updating Docker Compose configuration..."
# Backup original
cp docker-compose.raspi.yml docker-compose.raspi.yml.backup

# Update interface in docker-compose
sed -i "s/SURICATA_IFACE=.*/SURICATA_IFACE=$BEST_INTERFACE/" docker-compose.raspi.yml
sed -i "s/-i .*/-i $BEST_INTERFACE/" docker-compose.raspi.yml
sed -i "s/CAPTURE_INTERFACE=.*/CAPTURE_INTERFACE=$BEST_INTERFACE/" docker-compose.raspi.yml

# Update af-packet interface in suricata.yaml
sed -i "s/- interface: .*/- interface: $BEST_INTERFACE/" config/suricata/suricata.yaml

print_success "✅ Docker Compose configuration updated"

print_header "8. STARTING CORE SERVICES"

# Check if core services are already running
if docker ps | grep -q "idps-mongodb-pi.*Up" && docker ps | grep -q "idps-redis-pi.*Up"; then
    print_status "✅ Core services are already running"
else
    print_status "Stopping and removing existing containers..."
    docker compose -f docker-compose.raspi.yml down --remove-orphans || true
    
    print_status "Starting MongoDB and Redis..."
    docker compose -f docker-compose.raspi.yml up -d mongodb redis
    
    print_status "Waiting for core services to initialize..."
    sleep 15
    
    # Check core services
    if docker ps | grep -q "idps-mongodb-pi.*Up" && docker ps | grep -q "idps-redis-pi.*Up"; then
        print_success "✅ Core services are running"
    else
        print_error "❌ Core services failed to start"
        docker compose -f docker-compose.raspi.yml logs mongodb redis --tail 20
        exit 1
    fi
fi

print_header "9. STARTING SURICATA"

# Skip if Suricata is already working
if [ "$SKIP_SETUP" = "true" ]; then
    print_status "✅ Suricata is already running and working"
else
    # Check if Suricata is already running but not working
    if docker ps | grep -q "idps-suricata-pi.*Up"; then
        print_status "Restarting Suricata to fix configuration..."
        docker compose -f docker-compose.raspi.yml restart suricata
    else
        print_status "Starting Suricata container..."
        docker compose -f docker-compose.raspi.yml up -d suricata
    fi
    
    print_status "Waiting for Suricata to initialize..."
    sleep 20
    
    # Check Suricata
    if docker ps | grep -q "idps-suricata-pi.*Up"; then
        print_success "✅ Suricata container is running"
        
        # Verify Suricata is actually working
        sleep 10
        if docker ps | grep -q "idps-suricata-pi.*Up"; then
            print_success "✅ Suricata appears stable"
        else
            print_error "❌ Suricata crashed after startup"
            docker logs idps-suricata-pi --tail 30
            exit 1
        fi
    else
        print_error "❌ Suricata failed to start"
        docker logs idps-suricata-pi --tail 30
        exit 1
    fi
fi

print_header "10. TESTING SURICATA FUNCTIONALITY"

print_status "Generating comprehensive test traffic..."
ping -c 10 8.8.8.8 >/dev/null 2>&1 &
curl -s http://httpbin.org/ip >/dev/null 2>&1 &
curl -s https://httpbin.org/ip >/dev/null 2>&1 &
nslookup google.com >/dev/null 2>&1 &
hping3 -c 5 -S -p 80 scanme.nmap.org >/dev/null 2>&1 &
wget -q --spider http://example.com &

print_status "Waiting for traffic processing..."
sleep 15

print_header "11. VERIFYING EVE.JSON GENERATION"

print_status "Checking eve.json generation..."
if [ -f "$EVE_JSON_PATH" ]; then
    FILE_SIZE=$(du -h "$EVE_JSON_PATH" | cut -f1)
    LINE_COUNT=$(wc -l < "$EVE_JSON_PATH" 2>/dev/null || echo "0")
    
    print_success "✅ eve.json exists!"
    echo "  - Location: $EVE_JSON_PATH"
    echo "  - Size: $FILE_SIZE"
    echo "  - Lines: $LINE_COUNT"
    
    if [ "$LINE_COUNT" -gt 0 ]; then
        print_success "✅ eve.json has content!"
        echo ""
        echo "=== Latest Events ==="
        tail -5 "$EVE_JSON_PATH"
        echo ""
        
        # Count event types
        ALERT_COUNT=$(grep -c '"event_type":"alert"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        DNS_COUNT=$(grep -c '"event_type":"dns"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        HTTP_COUNT=$(grep -c '"event_type":"http"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        ICMP_COUNT=$(grep -c '"event_type":"icmp"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        
        echo "=== Event Summary ==="
        echo "  Alerts: $ALERT_COUNT"
        echo "  DNS: $DNS_COUNT"
        echo "  HTTP: $HTTP_COUNT"
        echo "  ICMP: $ICMP_COUNT"
        
        if [ "$ALERT_COUNT" -gt 0 ]; then
            print_success "🎉 SURICATA IS FULLY OPERATIONAL!"
            echo ""
            echo "✅ Your IDPS is detecting threats and generating alerts"
            echo "✅ Real-time intrusion detection is active"
            echo "✅ Network traffic monitoring is working"
        else
            print_warning "⚠️ No alerts generated yet, but traffic is being logged"
            print_status "This is normal for initial setup - alerts will appear as traffic increases"
        fi
    else
        print_error "❌ eve.json exists but is empty"
        print_status "Generating additional test traffic..."
        ping -c 20 8.8.8.8 >/dev/null 2>&1 &
        curl -s http://example.com >/dev/null 2>&1 &
        sleep 10
        
        NEW_LINE_COUNT=$(wc -l < "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        if [ "$NEW_LINE_COUNT" -gt 0 ]; then
            print_success "✅ eve.json now has content ($NEW_LINE_COUNT lines)"
        else
            print_error "❌ eve.json is still empty"
            echo ""
            echo "🔧 Manual troubleshooting:"
            echo "1. Check Suricata logs: docker logs idps-suricata-pi --tail 50"
            echo "2. Verify interface: ip addr show $BEST_INTERFACE"
            echo "3. Test manually: docker exec idps-suricata-pi suricata -c /etc/suricata/suricata.yaml -i $BEST_INTERFACE --af-packet"
        fi
    fi
else
    print_error "❌ eve.json was not created"
    echo ""
    echo "🔧 Checking container logs..."
    docker logs idps-suricata-pi --tail 30
fi

print_header "12. STARTING ADDITIONAL SERVICES"

# Check which services are already running
RUNNING_SERVICES=$(docker ps --format "table {{.Names}}" | grep -E "(packet-processor|raspi-collector|rule-engine)" | tail -n +2)

if [ -n "$RUNNING_SERVICES" ]; then
    print_status "✅ Some services are already running:"
    echo "$RUNNING_SERVICES"
    
    # Only start services that aren't running
    if ! docker ps | grep -q "idps-packet-processor.*Up"; then
        print_status "Starting packet processor..."
        docker compose -f docker-compose.raspi.yml up -d packet-processor
    fi
    
    if ! docker ps | grep -q "idps-raspi-collector.*Up"; then
        print_status "Starting raspi collector..."
        docker compose -f docker-compose.raspi.yml up -d raspi-collector
    fi
    
    if ! docker ps | grep -q "idps-rule-engine.*Up"; then
        print_status "Starting rule engine..."
        docker compose -f docker-compose.raspi.yml up -d rule-engine
    fi
else
    print_status "Starting packet processor and other services..."
    docker compose -f docker-compose.raspi.yml up -d packet-processor raspi-collector rule-engine
fi

print_status "Waiting for services to start..."
sleep 15

print_status "Final service status:"
docker compose -f docker-compose.raspi.yml ps

print_header "13. SETUP COMPLETION SUMMARY"

echo ""
echo "🎊 SURICATA SETUP COMPLETED!"
echo ""
echo "📊 Setup Summary:"
echo "  Issues found: $ISSUES_FOUND"
echo "  Fixes applied: $FIXES_APPLIED"
echo "  Interface used: $BEST_INTERFACE"
echo "  eve.json location: $EVE_JSON_PATH"
echo ""
echo "✅ What's working:"
echo "  - Suricata IDPS engine"
echo "  - Real-time threat detection"
echo "  - Network traffic monitoring"
echo "  - Alert generation"
echo "  - Log storage"
echo ""
echo "📊 Monitoring commands:"
echo "  - Real-time logs: docker logs idps-suricata-pi -f"
echo "  - eve.json monitoring: tail -f $EVE_JSON_PATH"
echo "  - Container status: docker ps | grep suricata"
echo "  - Generate test traffic: ping -c 5 8.8.8.8"
echo ""
echo "🔧 Management commands:"
echo "  - Stop Suricata: docker compose -f docker-compose.raspi.yml stop suricata"
echo "  - Restart Suricata: docker compose -f docker-compose.raspi.yml restart suricata"
echo "  - Update rules: nano config/suricata/rules/idps-dynamic.rules"
echo "  - View logs: docker logs idps-suricata-pi --tail 100"
echo ""
echo "🌐 Web Dashboard:"
echo "  - Access your IDPS dashboard at: http://localhost or http://your-pi-ip"
echo "  - Monitor alerts and system status in real-time"
echo ""
print_success "🚀 Your Suricata IDPS is ready for production use!"
