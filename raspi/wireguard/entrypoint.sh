#!/bin/sh
set -e

: "${WG_PRIVATE_KEY:?WG_PRIVATE_KEY is required}"
: "${WG_VPS_PUBLIC_KEY:?WG_VPS_PUBLIC_KEY is required}"

VPS_PUBLIC_IP="${VPS_PUBLIC_IP:-178.104.6.176}"
WG_PORT="${WG_PORT:-51820}"
WG_ADDRESS="${WG_ADDRESS:-10.10.0.2/24}"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-10.10.0.1/32}"
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"

# Load kernel module if not already loaded
modprobe wireguard 2>/dev/null || true

# Required by wg-quick for routing mark support
sysctl -w net.ipv4.conf.all.src_valid_mark=1 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = ${WG_ADDRESS}
PrivateKey = ${WG_PRIVATE_KEY}

[Peer]
PublicKey = ${WG_VPS_PUBLIC_KEY}
Endpoint = ${VPS_PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${WG_ALLOWED_IPS}
PersistentKeepalive = ${WG_KEEPALIVE}
EOF
chmod 600 /etc/wireguard/wg0.conf

cleanup() {
    echo "Bringing down WireGuard..."
    wg-quick down wg0 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
echo "WireGuard tunnel up"
wg show wg0

# Monitor tunnel; restart interface if it disappears
while true; do
    sleep 30
    if ! wg show wg0 > /dev/null 2>&1; then
        echo "wg0 interface gone, restarting..."
        wg-quick down wg0 2>/dev/null || true
        wg-quick up wg0
    fi
done
