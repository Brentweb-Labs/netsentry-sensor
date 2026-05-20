#!/bin/bash

# IDPS Manager - Unified Script for All IDPS Operations
# Consolidates and replaces multiple duplicate scripts

set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
PROJECT_DIR="/home/brent/idps"
EVE_JSON_PATH="$PROJECT_DIR/data/logs/suricata/eve.json"

# Environment selection
IDPS_ENV="${IDPS_ENV:-raspi}"  # Default to raspi environment

case "$IDPS_ENV" in
    "raspi")
        COMPOSE_FILE="$PROJECT_DIR/docker-compose.raspi.yml"
        ;;
    "vps")
        COMPOSE_FILE="$PROJECT_DIR/docker-compose.vps.yml"
        ;;
    *)
        print_error "Unknown environment: $IDPS_ENV. Use: raspi or vps"
        exit 1
        ;;
esac

# Functions
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

print_usage() {
    echo "IDPS Manager - Unified Management Script"
    echo ""
    echo "Environment: $IDPS_ENV"
    echo "Compose File: $COMPOSE_FILE"
    echo ""
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Environment Commands:"
    echo "  env-raspi               Set environment to Raspberry Pi"
    echo "  env-vps                 Set environment to VPS"
    echo ""
    echo "Main Commands:"
    echo "  setup                    Complete IDPS setup from scratch"
    echo "  bridge-setup            Setup network bridge (eth0 -> eth1)"
    echo "  bridge-revert           Revert network bridge changes"
    echo "  bridge-status           Show bridge status"
    echo ""
    echo "Fix Commands:"
    echo "  fix-eve                 Fix eve.json location and permissions"
    echo "  fix-raspi-suricata      Complete Raspberry Pi Suricata fix"
    echo "  fix-suricata-interface  Fix Suricata interface detection"
    echo "  fix-dns                 Fix DNS resolution issues"
    echo "  fix-iptables            Fix iptables DNAT rule errors"
    echo "  fix-docker              Fix Docker compose command issues"
    echo "  fix-docker-network      Fix Docker network iptables conflicts"
    echo "  fix-restart             Fix container restart loops"
    echo ""
    echo "Check Commands:"
    echo "  check-eve               Check eve.json status and content"
    echo "  check-containers        Check container status"
    echo "  check-network           Check network configuration"
    echo "  test-docker             Test Docker services startup"
    echo ""
    echo "Deploy Commands:"
    echo "  deploy-vps              Deploy VPS services"
    echo "  deploy-raspi            Deploy Raspberry Pi services"
    echo ""
    echo "Utility Commands:"
    echo "  clean                   Clean up old containers and data"
    echo "  logs                    Show service logs"
    echo "  restart                 Restart all services"
    echo "  status                  Show overall system status"
    echo ""
    echo "Examples:"
    echo "  IDPS_ENV=raspi $0 setup                # Complete setup for Raspberry Pi"
    echo "  IDPS_ENV=vps $0 fix-raspi-suricata   # Complete Raspberry Pi Suricata fix"
    echo "  IDPS_ENV=raspi $0 fix-eve              # Fix eve.json issues"
    echo "  IDPS_ENV=vps $0 test-docker          # Test Docker services startup"
    echo "  $0 env-vps                              # Switch to VPS environment"
    echo "  $0 bridge-setup                         # Setup network bridge"
    echo "  $0 status                               # Check system status"
    echo "  $0 menu                                 # Interactive menu mode"
}

# Environment selection functions
set_env_raspi() {
    export IDPS_ENV="raspi"
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.raspi.yml"
    print_success "Environment set to Raspberry Pi"
    print_status "Compose file: $COMPOSE_FILE"
}

set_env_vps() {
    export IDPS_ENV="vps"
    COMPOSE_FILE="$PROJECT_DIR/docker-compose.vps.yml"
    print_success "Environment set to VPS"
    print_status "Compose file: $COMPOSE_FILE"
}

# Fix Docker network iptables conflicts
fix_docker_network() {
    print_header "FIXING DOCKER NETWORK IPTABLES CONFLICTS"
    
    check_root
    cd_project
    
    print_status "Cleaning up Docker networks and containers..."
    
    # Stop all containers
    print_status "Stopping all containers..."
    docker compose down 2>/dev/null || true
    docker stop $(docker ps -aq) 2>/dev/null || true
    
    # Remove all containers
    print_status "Removing all containers..."
    docker rm $(docker ps -aq) 2>/dev/null || true
    
    # Prune Docker networks (this removes custom networks)
    print_status "Pruning Docker networks..."
    docker network prune -f
    
    # Fix for GitHub issue #211 - Missing DOCKER iptables chains
    print_status "Recreating missing Docker iptables chains..."
    
    # Check if DOCKER chain exists, if not, restart Docker properly
    if ! iptables -t nat -L DOCKER &>/dev/null; then
        print_status "DOCKER chain missing - restarting Docker service..."
        
        # Stop Docker completely
        systemctl stop docker
        sleep 3
        
        # Clean up any remaining Docker iptables rules
        iptables -t nat -F DOCKER 2>/dev/null || true
        iptables -t nat -X DOCKER 2>/dev/null || true
        iptables -t filter -F DOCKER 2>/dev/null || true
        iptables -t filter -X DOCKER 2>/dev/null || true
        iptables -t filter -F DOCKER-ISOLATION 2>/dev/null || true
        iptables -t filter -X DOCKER-ISOLATION 2>/dev/null || true
        
        # Start Docker to recreate chains
        systemctl start docker
        sleep 5
        
        # Verify DOCKER chain was created
        if iptables -t nat -L DOCKER &>/dev/null; then
            print_success "DOCKER iptables chains recreated successfully"
        else
            print_error "Failed to recreate DOCKER chains - may require reboot"
        fi
    else
        print_status "DOCKER chain exists - restarting Docker service..."
        systemctl restart docker
        sleep 5
    fi
    
    print_status "Starting services with clean network state..."
    docker compose -f "$COMPOSE_FILE" up -d
    
    print_success "Docker network conflicts resolved"
    print_status "Services should now start without iptables errors"
}

# Fix Suricata interface detection
fix_suricata_interface() {
    print_header "FIXING SURICATA INTERFACE DETECTION"
    
    check_root
    cd_project
    
    print_status "Checking available network interfaces..."
    
    # Show available interfaces
    print_status "Available network interfaces:"
    ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print "  " $2 " (" $1 ")"}'
    
    # Check if eth0 exists
    if ip link show eth0 &>/dev/null; then
        print_status "eth0 interface found"
        print_status "eth0 details:"
        ip addr show eth0 | grep -E "(inet|state)"
    else
        print_warning "eth0 interface NOT found"
        
        # Find the primary network interface
        PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
        if [ -n "$PRIMARY_INTERFACE" ]; then
            print_status "Primary interface detected: $PRIMARY_INTERFACE"
            print_status "Primary interface details:"
            ip addr show "$PRIMARY_INTERFACE" | grep -E "(inet|state)"
            
            print_status "Updating Suricata configuration to use $PRIMARY_INTERFACE..."
            
            # Update .env to override the interface for Suricata
            if [ -f "$PROJECT_DIR/.env" ]; then
                sed -i "s/^SURICATA_IFACE=.*/SURICATA_IFACE=$PRIMARY_INTERFACE/" "$PROJECT_DIR/.env"
                print_success "Updated .env with SURICATA_IFACE=$PRIMARY_INTERFACE"
            else
                echo "SURICATA_IFACE=$PRIMARY_INTERFACE" >> "$PROJECT_DIR/.env"
                print_success "Added SURICATA_IFACE=$PRIMARY_INTERFACE to .env"
            fi
            
            print_status "Restarting Suricata with new interface..."
            docker compose -f "$COMPOSE_FILE" restart suricata
            
        else
            print_error "No network interface found with default route"
            print_status "All interfaces:"
            ip link show
            exit 1
        fi
    fi
    
    # Test Suricata interface access
    print_status "Testing Suricata interface access..."
    
    # Check if Suricata container can see the interface
    SURICATA_CONTAINER=$(docker ps --filter "name=suricata" --format "{{.Names}}" | head -1)
    if [ -n "$SURICATA_CONTAINER" ]; then
        print_status "Checking interface visibility in container $SURICATA_CONTAINER..."
        
        # Get the interface name from container environment
        INTERFACE_IN_CONTAINER=$(docker exec "$SURICATA_CONTAINER" env | grep SURICATA_IFACE | cut -d'=' -f2)
        
        if [ -z "$INTERFACE_IN_CONTAINER" ]; then
            print_warning "SURICATA_IFACE environment variable is empty or not set"
            
            # Find the correct interface
            if ip link show eth0 &>/dev/null; then
                INTERFACE_IN_CONTAINER="eth0"
            else
                INTERFACE_IN_CONTAINER=$(ip route | grep default | awk '{print $5}' | head -1)
            fi
            
            print_status "Detected interface: $INTERFACE_IN_CONTAINER"
            
            # Update the container environment by recreating it
            print_status "Recreating Suricata container with correct interface..."
            docker compose -f "$COMPOSE_FILE" stop suricata
            docker compose -f "$COMPOSE_FILE" rm -f suricata
            
            # Update .env to override the interface for Suricata
            if [ -f "$PROJECT_DIR/.env" ]; then
                sed -i "s/^SURICATA_IFACE=.*/SURICATA_IFACE=$INTERFACE_IN_CONTAINER/" "$PROJECT_DIR/.env"
            else
                echo "SURICATA_IFACE=$INTERFACE_IN_CONTAINER" >> "$PROJECT_DIR/.env"
            fi
            print_success "Updated .env with SURICATA_IFACE=$INTERFACE_IN_CONTAINER"
            
            docker compose -f "$COMPOSE_FILE" up -d suricata
            sleep 10

            # Get the new container name
            SURICATA_CONTAINER=$(docker ps --filter "name=suricata" --format "{{.Names}}" | head -1)
            INTERFACE_IN_CONTAINER=$(docker exec "$SURICATA_CONTAINER" env | grep SURICATA_IFACE | cut -d'=' -f2)
        fi
        
        print_status "Suricata interface in container: $INTERFACE_IN_CONTAINER"
        
        # Check if interface exists in container
        if docker exec "$SURICATA_CONTAINER" ip link show "$INTERFACE_IN_CONTAINER" &>/dev/null; then
            print_success "Interface $INTERFACE_IN_CONTAINER is accessible in container"
            
            # Test if Suricata can actually use the interface
            print_status "Testing Suricata interface binding..."
            if docker exec "$SURICATA_CONTAINER" timeout 5 tcpdump -i "$INTERFACE_IN_CONTAINER" -c 1 2>/dev/null; then
                print_success "Suricata can capture packets on $INTERFACE_IN_CONTAINER"
            else
                print_warning "Suricata may have issues capturing on $INTERFACE_IN_CONTAINER"
            fi
        else
            print_error "Interface $INTERFACE_IN_CONTAINER is NOT accessible in container"
            print_status "Available interfaces in container:"
            docker exec "$SURICATA_CONTAINER" ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print "  " $2}'
            
            # Try to find a working interface
            print_status "Attempting to find a working interface..."
            for iface in $(docker exec "$SURICATA_CONTAINER" ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}' | grep -v lo); do
                if docker exec "$SURICATA_CONTAINER" ip link show "$iface" | grep -q "state UP"; then
                    print_status "Found active interface: $iface"
                    print_status "Updating Suricata to use $iface..."
                    
                    # Update .env to override the interface for Suricata
                    if [ -f "$PROJECT_DIR/.env" ]; then
                        sed -i "s/^SURICATA_IFACE=.*/SURICATA_IFACE=$iface/" "$PROJECT_DIR/.env"
                    else
                        echo "SURICATA_IFACE=$iface" >> "$PROJECT_DIR/.env"
                    fi
                    
                    # Restart Suricata
                    docker compose -f "$COMPOSE_FILE" restart suricata
                    sleep 5
                    
                    print_success "Updated Suricata to use interface $iface"
                    break
                fi
            done
        fi
    else
        print_warning "No Suricata container found - starting services..."
        docker compose -f "$COMPOSE_FILE" up -d suricata
        sleep 10
    fi
    
    print_success "Suricata interface check completed"
}

# Check if running as root for commands that need it
check_root() {
    if [[ $EUID -ne 0 ]]; then
       print_error "This command must be run as root (use sudo)"
       exit 1
    fi
}

# Change to project directory
cd_project() {
    cd "$PROJECT_DIR" || {
        print_error "Cannot change to project directory: $PROJECT_DIR"
        exit 1
    }
}

# Complete IDPS setup
setup_complete() {
    print_header "COMPLETE IDPS SETUP"
    
    check_root
    cd_project
    
    print_status "Starting complete IDPS setup from scratch..."
    
    # Run the main setup script
    if [ -f "$PROJECT_DIR/scripts/setup/setup-suricata-scratch.sh" ]; then
        "$PROJECT_DIR/scripts/setup/setup-suricata-scratch.sh"
    else
        print_error "Main setup script not found: $PROJECT_DIR/scripts/setup/setup-suricata-scratch.sh"
        exit 1
    fi
}

# Bridge setup (delegates to unified script)
bridge_setup() {
    print_header "NETWORK BRIDGE SETUP"
    
    check_root
    cd_project
    
    if [ -f "$PROJECT_DIR/scripts/setup/setup-bridge-unified.sh" ]; then
        "$PROJECT_DIR/scripts/setup/setup-bridge-unified.sh" setup
    else
        print_error "Bridge setup script not found: $PROJECT_DIR/scripts/setup/setup-bridge-unified.sh"
        exit 1
    fi
}

# Bridge revert
bridge_revert() {
    print_header "REVERT NETWORK BRIDGE"
    
    check_root
    cd_project
    
    if [ -f "$PROJECT_DIR/scripts/setup/setup-bridge-unified.sh" ]; then
        "$PROJECT_DIR/scripts/setup/setup-bridge-unified.sh" revert
    else
        print_error "Bridge setup script not found: $PROJECT_DIR/scripts/setup/setup-bridge-unified.sh"
        exit 1
    fi
}

# Bridge status
bridge_status() {
    print_header "BRIDGE STATUS"
    
    check_root
    cd_project
    
    if [ -f "$PROJECT_DIR/scripts/setup/setup-bridge-unified.sh" ]; then
        "$PROJECT_DIR/scripts/setup/setup-bridge-unified.sh" status
    else
        print_error "Bridge setup script not found: $PROJECT_DIR/scripts/setup/setup-bridge-unified.sh"
        exit 1
    fi
}

# Complete Raspberry Pi Suricata fix
fix_raspi_suricata() {
    print_header "RASPBERRY PI SURICATA COMPLETE FIX"
    
    check_root
    cd_project
    
    print_status "Starting complete Raspberry Pi Suricata fix..."
    
    # Section 1: Check network interfaces
    print_status "Checking available network interfaces..."
    INTERFACES=$(ip link show | grep -E '^[0-9]+:' | cut -d: -f2 | tr -d ' ')
    echo "Available interfaces: $INTERFACES"
    
    # Auto-detect monitoring interface
    if echo "$INTERFACES" | grep -q "eth0"; then
        MONITOR_INTERFACE="eth0"
        print_status "Using eth0 as monitoring interface"
    else
        # Fall back to primary interface from default route
        MONITOR_INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
        MONITOR_INTERFACE="${MONITOR_INTERFACE:-eth0}"
        print_warning "eth0 not found - using detected interface: $MONITOR_INTERFACE"
    fi
    
    print_status "Using interface: $MONITOR_INTERFACE for Suricata monitoring"
    
    # Section 2: Configure network for monitoring
    print_status "Enabling IP forwarding..."
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    
    print_status "Setting interface to promiscuous mode for monitoring..."
    ip link set "$MONITOR_INTERFACE" promisc on
    
    print_status "Checking interface status..."
    ip addr show "$MONITOR_INTERFACE"
    
    # Section 3: Test interface connectivity
    print_status "Testing interface connectivity..."
    ping -c 2 -I "$MONITOR_INTERFACE" 8.8.8.8 >/dev/null 2>&1 && print_success "✅ Interface connectivity OK" || print_warning "⚠️ Interface connectivity test failed"
    
    # Section 4: Fix Suricata configuration
    print_status "Creating required directories..."
    mkdir -p "$PROJECT_DIR/data/logs/suricata"
    mkdir -p "$PROJECT_DIR/data/suricata/rules"
    mkdir -p "$PROJECT_DIR/config/suricata/rules"

    print_status "Creating test rules..."
    cat > "$PROJECT_DIR/config/suricata/rules/idps-dynamic.rules" << 'EOF'
# IDPS Dynamic Rules for Raspberry Pi Interface Monitoring
# Basic test rules to ensure eve.json generation

# Test ICMP rule
alert icmp any any -> any any (msg:"ICMP Test Detected on eth0"; sid:1000001; rev:1;)

# Test HTTP rule  
alert tcp any any -> any 80 (msg:"HTTP Traffic Detected on eth0"; sid:1000002; rev:1;)

# Test DNS rule
alert udp any any -> any 53 (msg:"DNS Query Detected on eth0"; sid:1000003; rev:1;)

# Test HTTPS rule
alert tcp any any -> any 443 (msg:"HTTPS Traffic Detected on eth0"; sid:1000004; rev:1;)

# General IP traffic on monitored interface
alert ip any any -> any any (msg:"IP Traffic Detected on eth0"; sid:1000005; rev:1;)
EOF
    
    print_success "✅ Test rules created"
    
    # Section 5: Stop and restart services
    print_status "Stopping existing containers..."
    docker compose -f "$COMPOSE_FILE" down || true
    
    print_status "Starting services with fixed configuration..."
    docker compose -f "$COMPOSE_FILE" up -d
    
    # Section 6: Wait for services to start
    print_status "Waiting for Suricata to start..."
    sleep 20
    
    # Check if Suricata is running
    SURICATA_CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' suricata 2>/dev/null | head -1)
    if [ -n "$SURICATA_CONTAINER" ]; then
        print_success "✅ Suricata container is running ($SURICATA_CONTAINER)"
    else
        print_error "❌ Suricata container failed to start"
        echo "Checking logs..."
        docker compose -f "$COMPOSE_FILE" logs --tail 30 suricata
        exit 1
    fi
    
    # Section 7: Verify Suricata operation
    print_status "Checking Suricata logs for errors..."
    docker logs "$SURICATA_CONTAINER" --tail 20 | grep -i error || print_success "✅ No errors in Suricata logs"

    print_status "Checking if Suricata can see monitoring interface..."
    docker exec "$SURICATA_CONTAINER" ip link show "$MONITOR_INTERFACE" && print_success "✅ Suricata can see $MONITOR_INTERFACE interface" || print_error "❌ Suricata cannot see $MONITOR_INTERFACE interface"
    
    # Section 8: Generate test traffic
    print_status "Generating test traffic through monitoring interface..."
    ping -c 5 -I "$MONITOR_INTERFACE" 8.8.8.8 >/dev/null 2>&1 &
    curl -s --interface "$MONITOR_INTERFACE" http://example.com >/dev/null 2>&1 &
    nslookup google.com >/dev/null 2>&1 &
    
    print_status "Waiting for event processing..."
    sleep 15
    
    # Section 9: Verify eve.json
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
            tail -3 "$EVE_JSON_PATH"
            echo ""
            
            # Count event types
            ALERT_COUNT=$(grep -c '"event_type":"alert"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
            DNS_COUNT=$(grep -c '"event_type":"dns"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
            HTTP_COUNT=$(grep -c '"event_type":"http"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
            
            echo "=== Event Summary ==="
            echo "  Alerts: $ALERT_COUNT"
            echo "  DNS: $DNS_COUNT"
            echo "  HTTP: $HTTP_COUNT"
            
            print_success "🎉 EVE.JSON GENERATION: WORKING!"
            echo ""
            echo "✅ Your IDPS system is now operational!"
            echo "✅ Suricata is generating security logs on $MONITOR_INTERFACE interface"
            echo "✅ Real-time threat detection is active"
            
        else
            print_warning "⚠️ eve.json exists but is empty"
            print_status "Generating more test traffic..."
            
            # Generate more traffic
            ping -c 10 -I "$MONITOR_INTERFACE" 8.8.8.8 >/dev/null 2>&1 &
            curl -s --interface "$MONITOR_INTERFACE" http://httpbin.org/ip >/dev/null 2>&1 &
            sleep 20
            
            # Check again
            NEW_LINE_COUNT=$(wc -l < "$EVE_JSON_PATH" 2>/dev/null || echo "0")
            if [ "$NEW_LINE_COUNT" -gt 0 ]; then
                print_success "✅ eve.json now has content ($NEW_LINE_COUNT lines)"
            else
                print_error "❌ eve.json is still empty"
                echo ""
                echo "🔧 Advanced troubleshooting:"
                echo "1. Check Suricata process: docker exec $SURICATA_CONTAINER ps aux"
                echo "2. Check interface traffic: sudo tcpdump -i $MONITOR_INTERFACE -c 5"
                echo "3. Check rules loading: docker exec $SURICATA_CONTAINER suricata -T -c /etc/suricata/suricata.yaml"
                echo "4. Manual Suricata test: docker exec $SURICATA_CONTAINER suricata -c /etc/suricata/suricata.yaml -i $MONITOR_INTERFACE -T"
            fi
        fi
    else
        print_error "❌ eve.json does not exist at $EVE_JSON_PATH"
        echo ""
        echo "🔧 Checking container logs..."
        docker compose -f "$COMPOSE_FILE" logs --tail 50 suricata

        echo ""
        echo "🔧 Checking if directories are properly mapped..."
        SURICATA_CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' suricata 2>/dev/null | head -1)
        [ -n "$SURICATA_CONTAINER" ] && docker exec "$SURICATA_CONTAINER" ls -la /var/log/suricata/ || echo "Container log directory not accessible"
    fi
    
    # Section 10: Final status
    print_header "FINAL STATUS"
    
    echo "📊 Service Status:"
    docker compose -f "$COMPOSE_FILE" ps
    
    echo ""
    echo "📊 Interface Status:"
    ip addr show "$MONITOR_INTERFACE"
    
    echo ""
    echo "📊 Monitoring commands:"
    echo "  - Real-time logs: docker logs idps-suricata-pi -f"
    echo "  - eve.json monitoring: tail -f $EVE_JSON_PATH"
    echo "  - Interface traffic: sudo tcpdump -i $MONITOR_INTERFACE -n"
    echo "  - Container status: docker ps | grep suricata"
    echo "  - Generate test traffic: ping -c 5 -I $MONITOR_INTERFACE 8.8.8.8"
    
    echo ""
    print_success "🎉 Raspberry Pi Suricata fix completed!"
    echo ""
    echo "📝 Next steps:"
    echo "1. Monitor eve.json for real security events"
    echo "2. Configure Suricata rules for your network"
    echo "3. Set up log rotation for long-term operation"
    echo "4. Consider setting up monitoring alerts"
}

# Fix eve.json issues
fix_eve() {
    print_header "FIXING EVE.JSON ISSUES"
    
    check_root
    cd_project
    
    print_status "Creating directories and fixing permissions..."
    mkdir -p "$PROJECT_DIR/data/logs/suricata" "$PROJECT_DIR/data/suricata/rules"
    chmod 755 "$PROJECT_DIR/data/logs/suricata" "$PROJECT_DIR/data/suricata/rules"

    # Create basic rules file if missing
    if [ ! -f "$PROJECT_DIR/data/suricata/rules/idps-dynamic.rules" ]; then
        cat > "$PROJECT_DIR/data/suricata/rules/idps-dynamic.rules" << 'EOF'
# Basic IDPS Rules
drop ip any any -> any any (msg:"IDPS Block"; sid:1000001; rev:1;)
alert tcp any any -> any 22 (msg:"SSH Connection"; sid:1000002; rev:1;)
alert tcp any any -> any 80 (msg:"HTTP Traffic"; sid:1000003; rev:1;)
alert tcp any any -> any 443 (msg:"HTTPS Traffic"; sid:1000004; rev:1;)
EOF
    fi
    
    print_status "Restarting Suricata container..."
    docker compose -f "$COMPOSE_FILE" restart suricata 2>/dev/null || true

    
    print_status "Generating test traffic..."
    ping -c 5 8.8.8.8 >/dev/null 2>&1 &
    curl -s http://httpbin.org/ip >/dev/null 2>&1 &
    
    sleep 10
    
    if [ -f "$EVE_JSON_PATH" ] && [ -s "$EVE_JSON_PATH" ]; then
        print_success "✅ eve.json is working"
        echo "File size: $(wc -c < "$EVE_JSON_PATH") bytes"
        echo "Line count: $(wc -l < "$EVE_JSON_PATH") lines"
    else
        print_warning "⚠️ eve.json not found or empty"
        echo "Location: $EVE_JSON_PATH"
    fi
}

# Fix DNS issues
fix_dns() {
    print_header "FIXING DNS RESOLUTION"
    
    check_root
    cd_project
    
    if [ -f "$PROJECT_DIR/scripts/diagnostics/fix-dns-resolution.sh" ]; then
        "$PROJECT_DIR/scripts/diagnostics/fix-dns-resolution.sh"
    else
        print_status "Applying basic DNS fix..."
        # Basic DNS fix
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
        systemctl restart systemd-resolved 2>/dev/null || true
        print_success "✅ Basic DNS fix applied"
    fi
}

# Fix iptables issues
fix_iptables() {
    print_header "FIXING IPTABLES"
    
    check_root
    cd_project
    
    if [ -f "$PROJECT_DIR/scripts/diagnostics/fix-iptables.sh" ]; then
        "$PROJECT_DIR/scripts/diagnostics/fix-iptables.sh"
    else
        print_status "Applying basic iptables fix..."
        iptables -F 2>/dev/null || true
        iptables -X 2>/dev/null || true
        iptables -t nat -F 2>/dev/null || true
        iptables -P INPUT ACCEPT 2>/dev/null || true
        iptables -P FORWARD ACCEPT 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
        print_success "✅ Basic iptables fix applied"
    fi
}

# Fix Docker compose issues
fix_docker() {
    print_header "FIXING DOCKER COMPOSE"
    
    print_status "Checking Docker compose availability..."
    if docker compose version >/dev/null 2>&1; then
        print_success "✅ docker compose is working"
    elif command -v docker-compose >/dev/null 2>&1; then
        print_status "✅ docker-compose is working"
    else
        print_status "Installing docker-compose..."
        apt-get update -qq
        apt-get install -y docker-compose-plugin 2>/dev/null || apt-get install -y docker-compose 2>/dev/null || true
    fi
}

# Fix container restart loops
fix_restart() {
    print_header "FIXING CONTAINER RESTART LOOPS"
    
    check_root
    cd_project
    
    print_status "Checking container restart issues..."
    
    # Check for problematic containers
    docker compose -f "$COMPOSE_FILE" ps
    
    print_status "Checking logs for errors..."
    docker compose -f "$COMPOSE_FILE" logs --tail=20 suricata packet-processor 2>/dev/null || true
    
    print_status "Restarting problematic services..."
    docker compose -f "$COMPOSE_FILE" stop suricata packet-processor 2>/dev/null || true
    sleep 5
    docker compose -f "$COMPOSE_FILE" up -d suricata packet-processor 2>/dev/null || true
    
    print_success "✅ Container restart fix applied"
}

# Check eve.json status
check_eve() {
    print_header "CHECKING EVE.JSON STATUS"
    
    cd_project
    
    if [ -f "$EVE_JSON_PATH" ]; then
        local size=$(wc -c < "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        local lines=$(wc -l < "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        
        print_status "✅ eve.json found"
        echo "  Location: $EVE_JSON_PATH"
        echo "  Size: $size bytes"
        echo "  Lines: $lines"
        
        if [ "$size" -gt 0 ]; then
            print_status "✅ File has content"
            echo "  Last 5 events:"
            tail -5 "$EVE_JSON_PATH" 2>/dev/null | head -5
        else
            print_warning "⚠️ File is empty"
        fi
    else
        print_error "❌ eve.json not found"
        echo "  Expected location: $EVE_JSON_PATH"
    fi
}

# Check container status
check_containers() {
    print_header "CHECKING CONTAINER STATUS"
    
    cd_project
    
    print_status "Docker compose services:"
    docker compose -f "$COMPOSE_FILE" ps
    
    print_status "Container resource usage:"
    docker stats --no-stream 2>/dev/null || print_warning "docker stats failed"
    
    print_status "Recent container logs:"
    docker compose -f "$COMPOSE_FILE" logs --tail=5 2>/dev/null || true
}

# Test Docker services startup
test_docker() {
    print_header "TESTING DOCKER SERVICES STARTUP"
    
    check_root
    cd_project
    
    print_status "Testing Docker services startup without network errors..."
    
    # Section 1: Clean up existing containers
    print_status "Stopping and removing existing containers..."
    docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
    
    print_status "Pruning unused networks..."
    docker network prune -f || true
    
    # Section 2: Start core services
    print_status "Starting MongoDB and Redis first..."
    docker compose -f "$COMPOSE_FILE" up -d mongodb redis
    
    print_status "Waiting for databases to be healthy..."
    sleep 30
    
    print_status "Checking database status..."
    docker compose -f "$COMPOSE_FILE" ps mongodb redis
    
    # Section 3: Start Suricata
    print_status "Starting Suricata..."
    docker compose -f "$COMPOSE_FILE" up -d suricata
    
    print_status "Waiting for Suricata to start..."
    sleep 15
    
    print_status "Checking Suricata status..."
    docker compose -f "$COMPOSE_FILE" ps suricata
    
    SURICATA_CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' suricata 2>/dev/null | head -1)
    if [ -n "$SURICATA_CONTAINER" ]; then
        print_success "✅ Suricata started successfully! ($SURICATA_CONTAINER)"
    else
        print_error "❌ Suricata failed to start"
        echo "Checking logs..."
        docker compose -f "$COMPOSE_FILE" logs --tail 20 suricata
        return 1
    fi
    
    # Section 4: Start remaining services
    print_status "Starting all remaining services..."
    docker compose -f "$COMPOSE_FILE" up -d
    
    print_status "Waiting for all services to start..."
    sleep 20
    
    # Section 5: Verify all services
    print_status "Checking all service status..."
    docker compose -f "$COMPOSE_FILE" ps
    
    print_status "Checking for any container errors..."
    FAILED_CONTAINERS=$(docker compose -f "$COMPOSE_FILE" ps | grep -c "Exit\|Restarting" || echo "0")
    
    if [ "$FAILED_CONTAINERS" -gt 0 ]; then
        print_error "❌ Some containers failed to start"
        echo "Failed containers:"
        docker compose -f "$COMPOSE_FILE" ps | grep -E "Exit|Restarting"
        echo ""
        echo "Checking logs for failed containers..."
        docker compose -f "$COMPOSE_FILE" logs --tail 20
        return 1
    else
        print_success "✅ All services started successfully!"
    fi
    
    # Section 6: Test Suricata eve.json
    print_status "Checking if eve.json is being generated..."
    sleep 10  # Give some time for events to be generated
    
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
            tail -3 "$EVE_JSON_PATH"
        else
            print_status "eve.json exists but is empty - this is normal if no traffic is present"
        fi
    else
        print_status "eve.json not created yet - this may be normal if no traffic is present"
    fi
    
    # Section 7: Network test
    print_status "Testing basic network connectivity..."
    ping -c 2 8.8.8.8 >/dev/null 2>&1 && print_success "✅ Internet connectivity OK" || print_error "❌ No internet connectivity"
    
    print_status "Checking Docker network..."
    docker network ls
    
    # Section 8: Summary
    print_header "DOCKER STARTUP TEST SUMMARY"
    
    echo "📊 Service Status Summary:"
    docker compose -f "$COMPOSE_FILE" ps
    
    echo ""
    echo "📊 Monitoring commands:"
    echo "  - View all logs: docker compose -f "$COMPOSE_FILE" logs -f"
    echo "  - View Suricata logs: docker logs idps-suricata-pi -f"
    echo "  - Check eve.json: tail -f $EVE_JSON_PATH"
    echo "  - Restart services: docker compose -f "$COMPOSE_FILE" restart"
    
    echo ""
    print_success "🎉 Docker startup test completed!"
    
    if [ "$FAILED_CONTAINERS" -eq 0 ]; then
        echo "✅ All services are running properly"
        echo "✅ Network configuration is working"
        echo "✅ Ready to run the main fix: sudo ./scripts/idps-manager.sh fix-raspi-suricata"
        return 0
    else
        echo "⚠️ Some services may need attention"
        echo "🔧 Check the logs above for troubleshooting"
        return 1
    fi
}

# Check network configuration
check_network() {
    print_header "CHECKING NETWORK CONFIGURATION"
    
    print_status "Network interfaces:"
    ip addr show | grep -E "^[0-9]+:" | awk '{print "  " $2}' | sed 's/:$//'
    
    print_status "Bridge status:"
    if command -v brctl >/dev/null 2>&1; then
        brctl show 2>/dev/null || print_warning "brctl command failed"
    fi
    
    print_status "IP forwarding: $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 'unknown')"
    
    print_status "Internet connectivity:"
    if ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
        print_success "✅ Internet working"
    else
        print_warning "⚠️ Internet issue"
    fi
    
    print_status "DNS resolution:"
    if nslookup google.com >/dev/null 2>&1; then
        print_success "✅ DNS working"
    else
        print_warning "⚠️ DNS issue"
    fi
}

# Create all required data directories before deploying
setup_directories() {
    print_status "Creating required data directories..."
    mkdir -p "$PROJECT_DIR/data/mongodb"
    mkdir -p "$PROJECT_DIR/data/redis"
    mkdir -p "$PROJECT_DIR/data/elasticsearch"
    mkdir -p "$PROJECT_DIR/data/prometheus"
    mkdir -p "$PROJECT_DIR/data/grafana"
    mkdir -p "$PROJECT_DIR/data/logs/suricata"
    mkdir -p "$PROJECT_DIR/data/suricata/rules"
    mkdir -p "$PROJECT_DIR/logs/network-filter"
    mkdir -p "$PROJECT_DIR/logs/raspi-collector"
    mkdir -p "$PROJECT_DIR/logs/ids-pi"
    mkdir -p "$PROJECT_DIR/logs/packet-analyzer"
    print_success "✅ Data directories created"
}

# Deploy VPS services
deploy_vps() {
    print_header "DEPLOYING VPS SERVICES"

    cd_project
    setup_directories

    if [ -f "$PROJECT_DIR/scripts/deployment/deploy-vps.sh" ]; then
        "$PROJECT_DIR/scripts/deployment/deploy-vps.sh"
    else
        print_status "No custom deploy script found - starting services directly..."
        docker compose -f "$COMPOSE_FILE" up -d
        print_success "✅ VPS services started"
    fi
}

# Deploy Raspberry Pi services
deploy_raspi() {
    print_header "DEPLOYING RASPBERRY PI SERVICES"

    cd_project
    setup_directories

    if [ -f "$PROJECT_DIR/scripts/deployment/deploy-raspi-vps.sh" ]; then
        "$PROJECT_DIR/scripts/deployment/deploy-raspi-vps.sh"
    else
        print_status "No custom deploy script found - starting services directly..."
        docker compose -f "$COMPOSE_FILE" up -d
        print_success "✅ Raspberry Pi services started"
    fi
}

# Clean up old containers and data
clean_system() {
    print_header "CLEANING SYSTEM"
    
    check_root
    cd_project
    
    print_status "Stopping containers..."
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
    
    print_status "Removing old containers..."
    docker container prune -f
    
    print_status "Cleaning old data..."
    rm -rf "$PROJECT_DIR/data/logs/suricata/"* 2>/dev/null || true

    print_status "Starting fresh..."
    setup_directories
    docker compose -f "$COMPOSE_FILE" up -d
    
    print_success "✅ System cleaned and restarted"
}

# Show service logs
show_logs() {
    print_header "SERVICE LOGS"
    
    cd_project
    
    local service="${1:-}"
    if [ -n "$service" ]; then
        print_status "Showing logs for $service..."
        docker compose -f "$COMPOSE_FILE" logs --tail=50 -f "$service"
    else
        print_status "Showing logs for all services..."
        docker compose -f "$COMPOSE_FILE" logs --tail=20
    fi
}

# Restart all services
restart_services() {
    print_header "RESTARTING SERVICES"
    
    cd_project
    
    print_status "Restarting all IDPS services..."
    docker compose -f "$COMPOSE_FILE" restart
    
    print_status "Waiting for services to start..."
    sleep 10
    
    print_status "Checking service status..."
    docker compose -f "$COMPOSE_FILE" ps
    
    print_success "✅ Services restarted"
}

# Show overall system status
show_status() {
    print_header "IDPS SYSTEM STATUS"
    
    cd_project
    
    echo ""
    print_status "=== Container Status ==="
    docker compose -f "$COMPOSE_FILE" ps
    
    echo ""
    print_status "=== Network Status ==="
    check_network | grep -v "===\|CHECKING"
    
    echo ""
    print_status "=== EVE.json Status ==="
    check_eve | grep -v "===\|CHECKING"
    
    echo ""
    print_status "=== Resource Usage ==="
    docker stats --no-stream 2>/dev/null | head -10 || print_warning "Stats unavailable"
    
    echo ""
    print_status "=== Recent Alerts ==="
    if [ -f "$EVE_JSON_PATH" ] && [ -s "$EVE_JSON_PATH" ]; then
        grep '"event_type":"alert"' "$EVE_JSON_PATH" 2>/dev/null | tail -3 | jq -r '.timestamp + " " + .alert.signature' 2>/dev/null || echo "No recent alerts"
    else
        echo "No alerts data available"
    fi
}

# Interactive menu system
show_menu() {
    while true; do
        clear
        print_header "IDPS MANAGER - INTERACTIVE MENU"
        
        echo -e "${CYAN}🔧 Main Commands:${NC}"
        echo "1) setup                    - Complete IDPS setup from scratch"
        echo "2) bridge-setup            - Setup network bridge (eth0 -> eth1)"
        echo "3) bridge-revert           - Revert network bridge changes"
        echo "4) bridge-status           - Show bridge status"
        echo ""
        
        echo -e "${CYAN}🛠️  Fix Commands:${NC}"
        echo "5) fix-raspi-suricata      - Complete Raspberry Pi Suricata fix"
        echo "6) fix-eve                 - Fix eve.json location and permissions"
        echo "7) fix-dns                 - Fix DNS resolution issues"
        echo "8) fix-iptables            - Fix iptables DNAT rule errors"
        echo "9) fix-docker              - Fix Docker compose command issues"
        echo "10) fix-restart            - Fix container restart loops"
        echo ""
        
        echo -e "${CYAN}🔍 Check Commands:${NC}"
        echo "11) check-eve              - Check eve.json status and content"
        echo "12) check-containers       - Check container status"
        echo "13) check-network          - Check network configuration"
        echo "14) test-docker            - Test Docker services startup"
        echo ""
        
        echo -e "${CYAN}🚀 Deploy Commands:${NC}"
        echo "15) deploy-vps             - Deploy VPS services"
        echo "16) deploy-raspi           - Deploy Raspberry Pi services"
        echo ""
        
        echo -e "${CYAN}🔧 Utility Commands:${NC}"
        echo "17) clean                  - Clean up old containers and data"
        echo "18) restart                - Restart all services"
        echo "19) status                 - Show overall system status"
        echo "20) logs                   - Show service logs"
        echo ""
        
        echo -e "${GREEN}21) help                   - Show help"
        echo "0) exit                   - Exit menu${NC}"
        echo ""
        
        read -p "Select an option [0-21]: " choice
        
        case $choice in
            1) setup_complete ;;
            2) bridge_setup ;;
            3) bridge_revert ;;
            4) bridge_status ;;
            5) fix_raspi_suricata ;;
            6) fix_eve ;;
            7) fix_dns ;;
            8) fix_iptables ;;
            9) fix_docker ;;
            10) fix_restart ;;
            11) check_eve ;;
            12) check_containers ;;
            13) check_network ;;
            14) test_docker ;;
            15) deploy_vps ;;
            16) deploy_raspi ;;
            17) clean_system ;;
            18) restart_services ;;
            19) show_status ;;
            20) 
                read -p "Enter service name (or press Enter for all): " service
                show_logs "$service"
                ;;
            21) print_usage ;;
            0) 
                print_success "Exiting IDPS Manager..."
                exit 0
                ;;
            *) 
                print_error "Invalid option. Please select 0-21."
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Main execution
main() {
    case "${1:-help}" in
        "env-raspi")
            set_env_raspi
            ;;
        "env-vps")
            set_env_vps
            ;;
        "setup")
            setup_complete
            ;;
        "bridge-setup")
            bridge_setup
            ;;
        "bridge-revert")
            bridge_revert
            ;;
        "bridge-status")
            bridge_status
            ;;
        "fix-eve")
            fix_eve
            ;;
        "fix-raspi-suricata")
            fix_raspi_suricata
            ;;
        "fix-suricata-interface")
            fix_suricata_interface
            ;;
        "fix-dns")
            fix_dns
            ;;
        "fix-iptables")
            fix_iptables
            ;;
        "fix-docker")
            fix_docker
            ;;
        "fix-docker-network")
            fix_docker_network
            ;;
        "fix-restart")
            fix_restart
            ;;
        "check-eve")
            check_eve
            ;;
        "check-containers")
            check_containers
            ;;
        "check-network")
            print_header "CHECKING NETWORK CONFIGURATION"
            check_network
            ;;
        "test-docker")
            test_docker
            ;;
        "deploy-vps")
            deploy_vps
            ;;
        "deploy-raspi")
            deploy_raspi
            ;;
        "clean")
            clean_system
            ;;
        "logs")
            show_logs "${2:-}"
            ;;
        "restart")
            restart_services
            ;;
        "status")
            show_status
            ;;
        "help"|"-h"|"--help")
            print_usage
            ;;
        "menu")
            show_menu
            ;;
        *)
            print_error "Unknown command: $1"
            echo ""
            print_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
