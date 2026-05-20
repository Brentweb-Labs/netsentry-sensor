#!/bin/bash
# Install persistent IDPS bridge on Raspberry Pi
# Run once as root: sudo ./install.sh

set -e

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[*] Installing required packages..."
apt-get update -qq
apt-get install -y bridge-utils net-tools ifupdown curl isc-dhcp-server iptables-persistent docker-compose

echo "[*] Installing setup script..."
cp "$SCRIPT_DIR/setup-bridge-unified.sh" /usr/local/bin/setup-bridge-unified.sh
chmod +x /usr/local/bin/setup-bridge-unified.sh

echo "[*] Installing systemd service..."
cp "$SCRIPT_DIR/idps-bridge.service" /etc/systemd/system/idps-bridge.service
systemctl daemon-reload
systemctl enable idps-bridge.service

echo "[*] Running setup now..."
/usr/local/bin/setup-bridge-unified.sh setup

echo ""
echo "Done! The bridge + Docker services will start automatically on every reboot."
echo ""
echo "Manage with:"
echo "  systemctl status idps-bridge"
echo "  systemctl restart idps-bridge"
