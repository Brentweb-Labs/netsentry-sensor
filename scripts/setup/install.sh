#!/usr/bin/env bash
# NetSentry sensor one-line installer.
# Supports both prebuilt images (default) and local build.
#
# Usage:
#   Prebuilt images (recommended): curl ... | sudo bash
#   Local build: export NETSENTRY_BUILD_LOCAL=true && curl ... | sudo bash
#
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/netsentry"
GITHUB_RAW="https://raw.githubusercontent.com/yourorg/netsentry-sensor/main"
BUILD_LOCAL="${NETSENTRY_BUILD_LOCAL:-false}"

# Image registry
REGISTRY="ghcr.io/yourorg/netsentry"

# ── Privilege check ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash install.sh" >&2
  exit 1
fi

echo "=== NetSentry Sensor Installer ==="
echo ""
echo "  Build mode: $(if [[ "$BUILD_LOCAL" == "true" ]]; then echo "Local build (~16GB RAM required)"; else echo "Prebuilt images (recommended)"; fi)"
echo ""

# ── System requirements check ────────────────────────────────────────────────
check_ram() {
    local total_mem
    total_mem=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    echo "  System RAM: ${total_mem}GB"

    if [[ "$BUILD_LOCAL" == "true" ]] && [[ "$total_mem" -lt 14 ]]; then
        echo ""
        echo "  WARNING: Local build requires ~16GB RAM. You have ${total_mem}GB."
        echo "  Consider using prebuilt images instead:"
        echo "    curl -fsSL ... | bash"
        echo ""
        read -p "  Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}
check_ram

# ── Package dependencies ─────────────────────────────────────────────────────
echo "[1/7] Installing system packages…"
apt-get update -qq
apt-get install -y --no-install-recommends \
  curl ca-certificates wireguard-tools iptables-persistent docker.io docker-compose-plugin

# ── Install directory ────────────────────────────────────────────────────────
echo "[2/7] Creating ${INSTALL_DIR}…"
mkdir -p "${INSTALL_DIR}"

# ── Download required files from GitHub ─────────────────────────────────────
echo "[3/7] Downloading configuration files…"
for f in \
  "docker-compose.yml" \
  "scripts/setup/setup-bridge-unified.sh" \
  "scripts/setup/idps-bridge.service" \
  "setup-wireguard-pi.sh"; do
  dest="${INSTALL_DIR}/$(basename "${f}")"
  curl -fsSL "${GITHUB_RAW}/scripts/setup/${f}" -o "${dest}" 2>/dev/null || \
  curl -fsSL "${GITHUB_RAW}/${f}" -o "${dest}" 2>/dev/null || true
done
chmod +x "${INSTALL_DIR}"/setup-*.sh

# ── Pull or build Docker images ──────────────────────────────────────────────
echo "[4/7] Preparing Docker images…"
cd "${INSTALL_DIR}"

if [[ "$BUILD_LOCAL" == "true" ]]; then
    echo "  Building images locally (this needs ~16GB RAM)…”
    docker compose -f docker-compose.yml build
else
    echo "  Pulling prebuilt images from ${REGISTRY}…"
    docker compose -f docker-compose.yml pull || true
fi
echo "  Images ready."

# ── Collect configuration ────────────────────────────────────────────────────
echo "[5/7] Configuring NetSentry…"

if [[ -z "${VPS_ENDPOINT:-}" ]]; then
  read -rp "  VPS endpoint (e.g. https://idps.example.com): " VPS_ENDPOINT
fi

cat > "${INSTALL_DIR}/.env" <<EOF
VPS_ENDPOINT=${VPS_ENDPOINT}
WG_ADDRESS=10.10.0.2/24
WG_PORT=51820
WG_KEEPALIVE=25
EOF

# ── WireGuard keypair ────────────────────────────────────────────────────────
echo "[6/7] Generating WireGuard keypair…"
wg genkey | tee "${INSTALL_DIR}/wg-private" | wg pubkey > "${INSTALL_DIR}/wg-public"
chmod 600 "${INSTALL_DIR}/wg-private"
WG_PRIVATE=$(cat "${INSTALL_DIR}/wg-private")
WG_PUBLIC=$(cat "${INSTALL_DIR}/wg-public")
echo "      WG_PRIVATE_KEY=${WG_PRIVATE}" >> "${INSTALL_DIR}/.env"

echo ""
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  WireGuard public key (add this to your VPS peer config):    │"
echo "  │  ${WG_PUBLIC}"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""

# ── WireGuard Setup ───────────────────────────────────────────────────────────
setup_wireguard() {
    local vps_pubkey="${1:-}"

    echo "[*] Setting up WireGuard…"

    # Default values
    local wg_dir="/etc/wireguard"
    local wg_iface="wg0"
    local tunnel_ip="10.10.0.2/24"
    local vps_tunnel="10.10.0.1"
    local wg_port="51820"

    mkdir -p "$wg_dir"
    chmod 700 "$wg_dir"

    # Write WireGuard config
    cat > "$wg_dir/$wg_iface.conf << EOF
[Interface]
Address = $tunnel_ip
PrivateKey = $WG_PRIVATE
ListenPort = $wg_port

[Peer]
PublicKey = $vps_pubkey
Endpoint = $vps_tunnel:$wg_port
AllowedIPs = $vps_tunnel/32
PersistentKeepalive = 25
EOF
    chmod 600 "$wg_dir/$wg_iface.conf"

    # Enable and start WireGuard
    systemctl enable "wg-quick@$wg_iface" 2>/dev/null || true
    systemctl start "wg-quick@$wg_iface" 2>/dev/null || true

    echo "  WireGuard interface $wg_iface configured and started."
}

# Check if VPS public key is provided via environment or prompt
if [[ -n "${VPS_PUBLIC_KEY:-}" ]]; then
    setup_wireguard "${VPS_PUBLIC_KEY}"
elif [[ -n "${1:-}" ]]; then
    setup_wireguard "${1}"
else
    echo ""
    echo "  NOTE: Run again with VPS public key to complete WireGuard setup:"
    echo "    $0 <vps-public-key>"
    echo ""
    echo "  Or set environment variable: VPS_PUBLIC_KEY=<key>"
fi

# ── Systemd service ──────────────────────────────────────────────────────────
echo "[7/7] Installing and starting systemd service…"
cp "${INSTALL_DIR}/idps-bridge.service" /etc/systemd/system/idps-bridge.service

# Update service to auto-start docker compose
cat > /etc/systemd/system/idps-bridge.service << 'SERVICEEOF'
[Unit]
Description=NetSentry IDPS Bridge
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=/opt/netsentry
ExecStart=/usr/bin/docker compose -f docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f docker-compose.yml down
RemainAfterExit=yes
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable idps-bridge.service
systemctl start idps-bridge.service

# ── Health check ─────────────────────────────────────────────────────────────
echo ""
echo "Waiting for sensor to initialize…"
sleep 5

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Sensor is running! Check status with:"
echo "    systemctl status idps-bridge"
echo "    docker ps"
echo ""
echo "  View logs with:"
echo "    journalctl -u idps-bridge -f"
echo "    docker compose -f docker-compose.yml logs -f"
echo ""
echo "  Stop/Start:"
echo "    systemctl stop idps-bridge"
echo "    systemctl start idps-bridge"
echo ""
echo "  Update later with:"
echo "    docker compose -f docker-compose.yml pull"
echo "    systemctl restart idps-bridge"
