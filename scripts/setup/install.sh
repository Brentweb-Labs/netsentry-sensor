#!/usr/bin/env bash
# NetSentry sensor one-line installer.
# Usage: curl -fsSL https://raw.githubusercontent.com/yourorg/netsentry-sensor/main/scripts/setup/install.sh | sudo bash
set -euo pipefail

# ── Privilege check ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash install.sh" >&2
  exit 1
fi

INSTALL_DIR="/opt/netsentry"
GITHUB_RAW="https://raw.githubusercontent.com/yourorg/netsentry-sensor/main"

echo "=== NetSentry Sensor Installer ==="
echo ""

# ── Package dependencies ─────────────────────────────────────────────────────
echo "[1/6] Installing system packages…"
apt-get update -qq
apt-get install -y --no-install-recommends \
  curl ca-certificates wireguard-tools iptables-persistent

# Install Docker if not already present
if ! command -v docker &>/dev/null; then
  echo "      Installing Docker…"
  curl -fsSL https://get.docker.com | sh
fi

# ── Install directory ────────────────────────────────────────────────────────
echo "[2/6] Creating ${INSTALL_DIR}…"
mkdir -p "${INSTALL_DIR}"

# ── Download required files from GitHub ─────────────────────────────────────
echo "[3/6] Downloading configuration files…"
for f in \
  "docker-compose.raspi.yml" \
  "scripts/setup/setup-bridge-unified.sh" \
  "scripts/setup/idps-bridge.service"; do
  dest="${INSTALL_DIR}/$(basename "${f}")"
  curl -fsSL "${GITHUB_RAW}/${f}" -o "${dest}"
done
chmod +x "${INSTALL_DIR}/setup-bridge-unified.sh"

# ── Collect configuration ────────────────────────────────────────────────────
echo "[4/6] Configuring NetSentry…"

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
echo "[5/6] Generating WireGuard keypair…"
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

# ── Systemd service ──────────────────────────────────────────────────────────
echo "[6/6] Installing and starting systemd service…"
cp "${INSTALL_DIR}/idps-bridge.service" /etc/systemd/system/idps-bridge.service
systemctl daemon-reload
systemctl enable idps-bridge.service
systemctl start idps-bridge.service

# ── Health check ─────────────────────────────────────────────────────────────
echo ""
echo "Waiting for API gateway to become reachable…"
for i in {1..12}; do
  if curl -sf "${VPS_ENDPOINT}/health" >/dev/null 2>&1; then
    echo "  ✓ VPS endpoint is healthy."
    break
  fi
  sleep 5
done

echo ""
echo "=== Installation complete ==="
echo "  Manage with:  systemctl status idps-bridge"
echo "  Restart:      systemctl restart idps-bridge"
echo "  Logs:         journalctl -u idps-bridge -f"
echo ""
echo "  Use 'docker compose' (v2) to manage sensor containers:"
echo "    cd ${INSTALL_DIR} && docker compose -f docker-compose.raspi.yml up -d"
