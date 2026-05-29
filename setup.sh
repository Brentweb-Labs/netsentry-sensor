#!/usr/bin/env bash
# =============================================================================
# NetSentry Sensor — Setup & Management CLI
#
# Usage: ./setup.sh <command> [options]
#
# Run  ./setup.sh help  for a full list of commands.
# =============================================================================
set -euo pipefail

# ── Locate project root (directory containing this script) ───────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$ROOT/scripts"
COMPOSE_FILE="$ROOT/docker-compose.raspi.yml"
ENV_FILE="$ROOT/.env"
EVE_LOG="$ROOT/data/logs/suricata/eve.json"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BLUE}══ $* ══${NC}"; }
ok()      { echo -e "${GREEN}  ✓${NC} $*"; }
fail()    { echo -e "${RED}  ✗${NC} $*"; }
pending() { echo -e "${YELLOW}  ?${NC} $*"; }

require_root() {
    [[ $EUID -eq 0 ]] || error "This command must be run as root: sudo $0 $*"
}

require_env() {
    [[ -f "$ENV_FILE" ]] || error ".env not found — run:  cp .env.example .env  and fill in the required variables"
}

require_docker() {
    command -v docker &>/dev/null || error "Docker not found. Run:  ./setup.sh install"
    docker compose version &>/dev/null || error "Docker Compose plugin not found. Run:  ./setup.sh install"
}

# ── help ──────────────────────────────────────────────────────────────────────
cmd_help() {
    echo ""
    echo -e "${CYAN}NetSentry Sensor — setup.sh${NC}"
    echo ""
    echo "  USAGE"
    echo "    ./setup.sh <command> [options]"
    echo ""
    echo "  SETUP COMMANDS"
    echo -e "    ${GREEN}install${NC}                   Install Docker, start sensor stack, install systemd service"
    echo -e "    ${GREEN}wireguard${NC}                 Interactive WireGuard setup for this sensor node"
    echo -e "    ${GREEN}wireguard-cloud${NC}           Interactive WireGuard setup for the cloud server"
    echo -e "    ${GREEN}bridge${NC} [revert|status]    Inline bridge setup (eth0 → eth1)"
    echo -e "    ${GREEN}span${NC} [status]             Verify SPAN / switch port-mirroring configuration"
    echo ""
    echo "  RUNTIME COMMANDS"
    echo -e "    ${GREEN}up${NC}                        Start the sensor stack (docker compose up -d)"
    echo -e "    ${GREEN}down${NC}                      Stop the sensor stack"
    echo -e "    ${GREEN}restart${NC} [service]         Restart all services or a single one"
    echo -e "    ${GREEN}logs${NC} [service]            Follow logs (all services or one)"
    echo -e "    ${GREEN}status${NC}                    Health overview of all services + WireGuard tunnel"
    echo ""
    echo "  DEVELOPMENT COMMANDS"
    echo -e "    ${GREEN}build${NC}                     Build all Rust services from source"
    echo -e "    ${GREEN}diagnose${NC}                  Run full diagnostics (Suricata, WireGuard, eve.json)"
    echo ""
    echo "  EXAMPLES"
    echo "    ./setup.sh install                      # First-time setup on a new machine"
    echo "    ./setup.sh wireguard                    # Configure WireGuard keys for this sensor"
    echo "    ./setup.sh bridge                       # Set up inline bridge (requires two NICs)"
    echo "    ./setup.sh bridge revert                # Remove inline bridge configuration"
    echo "    ./setup.sh span status                  # Verify mirror port is delivering traffic"
    echo "    ./setup.sh status                       # Quick health check"
    echo "    ./setup.sh logs raspi-collector         # Follow a specific service's logs"
    echo "    ./setup.sh diagnose                     # Full diagnostic run"
    echo ""
}

# ── install ───────────────────────────────────────────────────────────────────
cmd_install() {
    require_root "install"

    header "Installing dependencies"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg lsb-release \
        wireguard-tools iptables-persistent jq

    # Install Docker if missing
    if ! command -v docker &>/dev/null; then
        info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
    else
        info "Docker already installed"
    fi

    # Install systemd service
    header "Installing systemd service"
    cp "$SCRIPTS/netsentry.service" /etc/systemd/system/netsentry.service
    # Update WorkingDirectory to this repo's location
    sed -i "s|WorkingDirectory=.*|WorkingDirectory=$ROOT|" /etc/systemd/system/netsentry.service
    sed -i "s|docker-compose.raspi.yml|$COMPOSE_FILE|g" /etc/systemd/system/netsentry.service
    systemctl daemon-reload
    systemctl enable netsentry
    info "Systemd service installed and enabled"

    # Configure .env if missing
    if [[ ! -f "$ENV_FILE" ]]; then
        cp "$ROOT/.env.example" "$ENV_FILE"
        warn ".env created from .env.example — edit it and fill in the required variables:"
        warn "  API_KEY, VPS_PUBLIC_IP, WG_PRIVATE_KEY, WG_VPS_PUBLIC_KEY, VPS_API_URL"
    fi

    header "Starting sensor stack"
    require_env
    cd "$ROOT"
    docker compose -f "$COMPOSE_FILE" up -d

    echo ""
    info "Install complete. Use  ./setup.sh status  to check services."
    echo ""
    info "If WireGuard keys are not yet set in .env, run:"
    echo "   ./setup.sh wireguard"
}

# ── wireguard (sensor side) ───────────────────────────────────────────────────
cmd_wireguard() {
    require_root "wireguard"
    bash "$SCRIPTS/setup/setup-wireguard-pi.sh" "$@"
}

# ── wireguard-cloud (cloud server side) ──────────────────────────────────────
cmd_wireguard_cloud() {
    require_root "wireguard-cloud"
    bash "$SCRIPTS/setup/setup-wireguard-vps.sh" "$@"
}

# ── bridge ────────────────────────────────────────────────────────────────────
cmd_bridge() {
    require_root "bridge $*"
    local action="${1:-setup}"
    case "$action" in
        setup|"")  bash "$SCRIPTS/setup/setup-bridge-unified.sh" setup ;;
        revert)    bash "$SCRIPTS/setup/setup-bridge-unified.sh" revert ;;
        status)    bash "$SCRIPTS/setup/setup-bridge-unified.sh" status ;;
        *)         error "Unknown bridge action '$action'. Use: setup | revert | status" ;;
    esac
}

# ── span ──────────────────────────────────────────────────────────────────────
cmd_span() {
    local action="${1:-status}"
    case "$action" in
        status|"") bash "$SCRIPTS/setup/setup-span-port.sh" status ;;
        configure) bash "$SCRIPTS/setup/setup-span-port.sh" configure ;;
        *)         error "Unknown span action '$action'. Use: status | configure" ;;
    esac
}

# ── up / down / restart ───────────────────────────────────────────────────────
cmd_up() {
    require_env
    require_docker
    cd "$ROOT"
    docker compose -f "$COMPOSE_FILE" up -d "$@"
    info "Stack started."
}

cmd_down() {
    require_docker
    cd "$ROOT"
    docker compose -f "$COMPOSE_FILE" down "$@"
    info "Stack stopped."
}

cmd_restart() {
    require_docker
    cd "$ROOT"
    if [[ $# -gt 0 ]]; then
        info "Restarting service: $1"
        docker compose -f "$COMPOSE_FILE" restart "$1"
    else
        info "Restarting all services..."
        docker compose -f "$COMPOSE_FILE" restart
    fi
}

# ── logs ──────────────────────────────────────────────────────────────────────
cmd_logs() {
    require_docker
    cd "$ROOT"
    if [[ $# -gt 0 ]]; then
        docker compose -f "$COMPOSE_FILE" logs -f --tail=100 "$1"
    else
        docker compose -f "$COMPOSE_FILE" logs -f --tail=50
    fi
}

# ── status ────────────────────────────────────────────────────────────────────
cmd_status() {
    require_docker

    header "Sensor Stack"
    cd "$ROOT"
    docker compose -f "$COMPOSE_FILE" ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
    docker compose -f "$COMPOSE_FILE" ps

    header "WireGuard Tunnel"
    if docker exec idps-wireguard wg show wg0 2>/dev/null; then
        :
    elif command -v wg &>/dev/null && wg show wg0 &>/dev/null 2>&1; then
        wg show wg0
    else
        warn "WireGuard interface wg0 not found"
    fi

    header "eve.json"
    if [[ -f "$EVE_LOG" ]]; then
        local lines size
        lines=$(wc -l < "$EVE_LOG")
        size=$(du -sh "$EVE_LOG" | cut -f1)
        ok "exists — $lines events, $size"
        echo "  Latest event:"
        tail -1 "$EVE_LOG" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('    type={} src={} time={}'.format(d.get('event_type','?'), d.get('src_ip','?'), d.get('timestamp','?')))" 2>/dev/null || tail -1 "$EVE_LOG"
    else
        warn "eve.json not found at $EVE_LOG"
    fi

    header "Capture Interface"
    local iface
    iface=$(grep -E '^CAPTURE_INTERFACE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "eth0")
    if ip link show "$iface" &>/dev/null; then
        local rx
        rx=$(cat "/sys/class/net/$iface/statistics/rx_packets" 2>/dev/null || echo "?")
        ok "$iface is UP — rx_packets: $rx"
    else
        fail "Interface $iface not found"
    fi

    echo ""
}

# ── diagnose ──────────────────────────────────────────────────────────────────
cmd_diagnose() {
    local issues=0

    header "1. Docker"
    if docker ps &>/dev/null; then
        ok "Docker is running"
    else
        fail "Docker is not running"; ((issues++))
    fi

    header "2. Sensor Containers"
    cd "$ROOT"
    local expected=(idps-wireguard idps-suricata-pi idps-raspi-collector-pi idps-mongodb-pi idps-network-filter-pi)
    for name in "${expected[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^$name$"; then
            ok "$name is running"
        else
            fail "$name is NOT running"; ((issues++))
        fi
    done

    header "3. WireGuard Tunnel"
    if docker exec idps-wireguard wg show wg0 &>/dev/null 2>&1; then
        local handshake
        handshake=$(docker exec idps-wireguard wg show wg0 2>/dev/null | grep 'latest handshake' | awk '{print $NF}')
        if [[ -n "$handshake" ]]; then
            ok "Tunnel established — last handshake: $handshake"
        else
            warn "Interface up but no handshake yet (check VPS has sensor's WireGuard public key)"
            ((issues++))
        fi
    else
        fail "WireGuard container not running or wg0 not up"; ((issues++))
    fi

    header "4. Cloud Reachability"
    local vps_url
    vps_url=$(grep -E '^VPS_API_URL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
    if [[ -n "$vps_url" ]]; then
        local health_url="${vps_url%%/api/vps*}/health"
        if curl -sf --max-time 5 "$health_url" &>/dev/null; then
            ok "Cloud reachable: $health_url"
        else
            fail "Cloud NOT reachable at $health_url"; ((issues++))
        fi
    else
        warn "VPS_API_URL not set in .env — skipping cloud check"
    fi

    header "5. Suricata / eve.json"
    if [[ -f "$EVE_LOG" ]]; then
        local lines
        lines=$(wc -l < "$EVE_LOG")
        ok "eve.json exists — $lines events"
        if [[ $lines -eq 0 ]]; then
            warn "eve.json is empty — generating test traffic (ping 8.8.8.8)..."
            ping -c 3 8.8.8.8 &>/dev/null || true
            sleep 3
            lines=$(wc -l < "$EVE_LOG")
            if [[ $lines -gt 0 ]]; then
                ok "Now has $lines events"
            else
                fail "Still empty — check SURICATA_IFACE and capture interface"; ((issues++))
            fi
        fi
    else
        fail "eve.json not found at $EVE_LOG"; ((issues++))
        info "Fix: ensure data/logs/suricata/ directory exists and Suricata is running"
    fi

    header "6. Capture Interface"
    local iface
    iface=$(grep -E '^CAPTURE_INTERFACE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "eth0")
    if ip link show "$iface" &>/dev/null 2>&1; then
        local state
        state=$(ip link show "$iface" | grep -o 'state [A-Z]*' | awk '{print $2}')
        local rx
        rx=$(cat "/sys/class/net/$iface/statistics/rx_packets" 2>/dev/null || echo "?")
        ok "$iface is $state — rx_packets: $rx"
        if [[ "$rx" == "0" || "$rx" == "?" ]]; then
            warn "No packets received on $iface — verify switch port mirroring"
            ((issues++))
        fi
    else
        fail "Interface $iface not found — check CAPTURE_INTERFACE in .env"; ((issues++))
    fi

    header "7. iptables"
    if iptables -L DOCKER-USER -n &>/dev/null 2>&1; then
        local blocked
        blocked=$(iptables -L DOCKER-USER -n 2>/dev/null | grep -c DROP || echo 0)
        ok "iptables working — $blocked active DROP rules"
    else
        warn "DOCKER-USER chain not found (expected after Docker starts)"
    fi

    header "Diagnosis Summary"
    if [[ $issues -eq 0 ]]; then
        ok "All checks passed — sensor is healthy"
    else
        fail "$issues issue(s) found — review the output above"
    fi
    echo ""
    return $issues
}

# ── build ─────────────────────────────────────────────────────────────────────
cmd_build() {
    bash "$SCRIPTS/build.sh" "$@"
}

# ── main dispatcher ───────────────────────────────────────────────────────────
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    install)          cmd_install "$@" ;;
    wireguard)        cmd_wireguard "$@" ;;
    wireguard-cloud)  cmd_wireguard_cloud "$@" ;;
    bridge)           cmd_bridge "$@" ;;
    span)             cmd_span "$@" ;;
    up)               cmd_up "$@" ;;
    down)             cmd_down "$@" ;;
    restart)          cmd_restart "$@" ;;
    logs)             cmd_logs "$@" ;;
    status)           cmd_status ;;
    diagnose)         cmd_diagnose ;;
    build)            cmd_build "$@" ;;
    help|--help|-h)   cmd_help ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        cmd_help
        exit 1
        ;;
esac
