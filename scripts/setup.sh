#!/bin/bash
# NetSentry Sensor Quick Setup
# Downloads prebuilt binaries automatically, falls back to local build if needed
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup.sh | sudo bash -s <vps-public-key>
#
set -euo pipefail

# Configuration
INSTALL_DIR="/opt/netsentry"
GITHUB_ORG="${GITHUB_ORG:-Brentweb-Labs}"
NETSENTRY_BUILD_LOCAL="${NETSENTRY_BUILD_LOCAL:-false}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check if running as root
[[ $EUID -ne 0 ]] && error "Run as root: sudo $0"

echo "=== NetSentry Sensor Quick Setup ==="
echo ""

# ── System Check ─────────────────────────────────────────────────────────────
log "Checking system..."

# RAM check
RAM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
log "System RAM: ${RAM_GB}GB"

# Architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  TARGET="x86_64-unknown-linux-gnu"; ARCH_NAME="AMD64" ;;
    aarch64) TARGET="aarch64-unknown-linux-gnu"; ARCH_NAME="ARM64" ;;
    *) error "Unsupported architecture: $ARCH" ;;
esac
log "Architecture: $ARCH_NAME"

# ── Install Dependencies ─────────────────────────────────────────────────────
log "Installing system packages..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    curl ca-certificates wireguard-tools iptables-persistent \
    docker.io docker-compose-plugin jq >/dev/null 2>&1 || true

# Create install directory
mkdir -p "$INSTALL_DIR"

# ── Download Project ─────────────────────────────────────────────────────────
log "Downloading NetSentry..."
curl -fsSL "https://raw.githubusercontent.com/${GITHUB_ORG}/netsentry-sensor/main/docker-compose.raspi.yml" \
    -o "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || \
curl -fsSL "https://raw.githubusercontent.com/${GITHUB_ORG}/netsentry-sensor/main/docker-compose.yml" \
    -o "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || \
error "Failed to download docker-compose.yml"

# ── Download Prebuilt Binaries ──────────────────────────────────────────────
log "Checking for prebuilt binaries..."

# Determine GitHub API URL for releases
API_URL="https://api.github.com/repos/Brentweb-Labs/netsentry-sensor/releases/latest"

# Try to get download URL from latest release
PREBUILT_URL=""
if command -v jq >/dev/null 2>&1; then
    PREBUILT_URL=$(curl -sf "$API_URL" 2>/dev/null | jq -r '.assets[] | select(.name | contains("'"$ARCH_NAME"'")) | .browser_download_url' 2>/dev/null | head -1)
fi

# Services to download
SERVICES=(
    "idps-packet-processor"
    "idps-network-filter"
    "idps-rule-engine"
    "raspi-collector"
    "idps-firewall-forwarder"
    "idps-telemetry"
)

mkdir -p "$INSTALL_DIR/bin"

if [[ -n "$PREBUILT_URL" ]] && [[ "$NETSENTRY_BUILD_LOCAL" != "true" ]]; then
    log "Found prebuilt binaries, downloading..."
    for svc in "${SERVICES[@]}"; do
        url="${PREBUILT_URL//\*-linux-$ARCH_NAME.*/}-$svc"
        if curl -sfL "$url" -o "$INSTALL_DIR/bin/$svc" 2>/dev/null; then
            chmod +x "$INSTALL_DIR/bin/$svc"
            log "  Downloaded: $svc"
        else
            warn "  Not found: $svc (will build if needed)"
        fi
    done
else
    warn "No prebuilt binaries available - will build from source"
    warn "Set NETSENTRY_BUILD_LOCAL=false to always try prebuilt first"
fi

# ── Generate WireGuard Keys ──────────────────────────────────────────────────
log "Generating WireGuard keys..."
wg genkey | tee "$INSTALL_DIR/wg-private" | wg pubkey > "$INSTALL_DIR/wg-public"
chmod 600 "$INSTALL_DIR/wg-private"

WG_PRIVATE=$(cat "$INSTALL_DIR/wg-private")
WG_PUBLIC=$(cat "$INSTALL_DIR/wg-public")

# ── Configuration ───────────────────────────────────────────────────────────
log "Creating configuration..."

if [[ -z "${VPS_ENDPOINT:-}" ]]; then
    read -rp "  VPS endpoint (e.g. https://idps.example.com): " VPS_ENDPOINT
fi

VPS_PUBKEY="${1:-${VPS_PUBLIC_KEY:-}}"

cat > "$INSTALL_DIR/.env" << EOF
VPS_ENDPOINT=${VPS_ENDPOINT}
WG_ADDRESS=10.10.0.2/24
WG_PORT=51820
WG_KEEPALIVE=25
WG_PRIVATE_KEY=${WG_PRIVATE}
EOF

if [[ -n "$VPS_PUBKEY" ]]; then
    echo "WG_VPS_PUBLIC_KEY=$VPS_PUBKEY" >> "$INSTALL_DIR/.env"
    log "VPS public key configured"
else
    warn "VPS public key not provided - edit .env to add it"
fi

# ── Start Services ───────────────────────────────────────────────────────────
log "Starting Docker containers..."
cd "$INSTALL_DIR"
docker compose -f docker-compose.yml up -d

# ── Wait for Health ─────────────────────────────────────────────────────────
log "Waiting for services to become healthy..."
sleep 10

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Setup Complete ==="
echo ""
echo "  WireGuard Public Key (share with VPS):"
echo "    $WG_PUBLIC"
echo ""
echo "  Sensor Status:"
docker compose -f docker-compose.yml ps
echo ""
echo "  Logs:"
echo "    docker compose -f docker-compose.yml logs -f"
echo ""
echo "  Stop/Start:"
echo "    systemctl stop netsentry"
echo "    systemctl start netsentry"
echo ""
if [[ -z "$VPS_PUBKEY" ]]; then
    echo "  To complete WireGuard setup, run with VPS public key:"
    echo "    sudo $0 <vps-public-key>"
fi
