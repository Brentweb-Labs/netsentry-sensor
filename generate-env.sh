#!/usr/bin/env bash
# generate-env.sh — Generate a .env file with random secrets from .env.example
# Usage: ./generate-env.sh [output-file]   (default: .env)

set -euo pipefail

OUTPUT="${1:-.env}"

if [[ -f "$OUTPUT" ]]; then
    read -r -p ".env already exists. Overwrite? [y/N] " confirm
    confirm_lc=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
    [ "$confirm_lc" = "y" ] || { echo "Aborted."; exit 0; }
fi

rand32()  { openssl rand -hex 32; }
rand24()  { openssl rand -hex 24; }
rand16()  { openssl rand -hex 16; }

MONGO_ROOT_PASSWORD="$(rand24)"
REDIS_PASSWORD="$(rand24)"
JWT_SECRET="$(rand32)"
API_KEY="$(rand32)"
VPS_API_KEY="${API_KEY}"
ADMIN_PASSWORD="$(rand24)"
DOCS_PASSWORD="$(rand16)"
GRAFANA_PASSWORD="$(rand16)"

cat > "$OUTPUT" <<EOF
# IDPS Environment — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Keep this file secret and never commit it to version control.

# =============================================================================
# DATABASE
# =============================================================================

MONGO_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD}
MONGODB_URI=mongodb://admin:${MONGO_ROOT_PASSWORD}@localhost:27017/idps_database?authSource=admin

REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_URL=redis://:${REDIS_PASSWORD}@localhost:6379

# =============================================================================
# AUTHENTICATION
# =============================================================================

JWT_SECRET=${JWT_SECRET}
API_KEY=${API_KEY}
VPS_API_KEY=${VPS_API_KEY}
ADMIN_USERNAME=admin
ADMIN_PASSWORD=${ADMIN_PASSWORD}

DOCS_PASSWORD=${DOCS_PASSWORD}
GRAFANA_PASSWORD=${GRAFANA_PASSWORD}

# =============================================================================
# TLS
# =============================================================================

TLS_ENABLED=false
TLS_CERT_PATH=/etc/ssl/certs/idps.crt
TLS_KEY_PATH=/etc/ssl/private/idps.key

# =============================================================================
# WIREGUARD TUNNEL (Raspberry Pi side)
# =============================================================================

# Pi's WireGuard private key (generate with: wg genkey)
WG_PRIVATE_KEY=

# VPS WireGuard public key (printed by setup-wireguard-vps.sh)
WG_VPS_PUBLIC_KEY=kbQZiq7EKWVYv+eMwbmyplCVPNZzwJ9DWyE9wJ+aNDc=

# VPS public IP — update if it changes
VPS_PUBLIC_IP=178.104.6.176

# Tunnel settings (defaults match the setup scripts)
WG_ADDRESS=10.10.0.2/24
WG_PORT=51820
WG_ALLOWED_IPS=10.10.0.1/32
WG_KEEPALIVE=25

# =============================================================================
# CONNECTIVITY — VPS <-> Raspberry Pi
# =============================================================================

VPS_API_URL=https://idps.brentweb.eu/api/vps
VPS_URL=https://idps.brentweb.eu/api/vps
VPS_ENDPOINT=http://10.10.0.1:8080
VPS_PROCESSOR_URL=http://10.10.0.1:8080

VPS_WS_URL=wss://idps.brentweb.eu/ws/raspi
VPS_PACKETS_WS_URL=wss://idps.brentweb.eu/ws/packets
PACKET_STREAM_WS_URL=wss://idps.brentweb.eu/ws/packets

RASPI_HOST=10.10.0.2
RASPI_IP=10.10.0.2
RASPI_ENDPOINT=http://10.10.0.2:8080

NETWORK_FILTER_URL=http://network-filter:8092/api/v1
RULE_ENGINE_URL=http://rule-engine:8094/api/v1
RASPI_URL=http://api-gateway:8080

# =============================================================================
# NETWORK / PACKET CAPTURE
# =============================================================================

CAPTURE_INTERFACE=eth0
PCAP_INTERFACE=eth0
RASPI_INTERFACE=eth1
NETWORK_INTERFACE=eth1

HOST_NETNS_PATH=/host_proc/1/ns/net

# =============================================================================
# SURICATA
# =============================================================================

SURICATA_IFACE=eth0
EVE_JSON_PATH=/app/logs/eve.json
SURICATA_EVE_PATH=/var/log/suricata/eve.json
SURICATA_CUSTOM_RULES=/etc/suricata/rules/idps-custom.rules

# =============================================================================
# DETECTION & BLOCKING
# =============================================================================

AUTO_BLOCK_ENABLED=false
DEFAULT_BLOCK_DURATION_HOURS=24
TTL_CLEANUP_INTERVAL_SECS=300
MAX_PACKETS_PER_SECOND=10000
RATE_LIMITING_ENABLED=true

# =============================================================================
# TELEMETRY SERVICE (edge device)
# =============================================================================

DEVICE_ID=raspi-edge-01
COLLECTION_INTERVAL_SECS=10
TELEMETRY_PORT=8096

# =============================================================================
# SERVICE PORTS
# =============================================================================

API_GATEWAY_PORT=8080
SERVICE_PORT=8080
WEBSOCKET_PORT=8080
RULE_ENGINE_PORT=8094
COLLECTOR_PORT=8091

# =============================================================================
# LOGGING
# =============================================================================

RUST_LOG=info
LOG_LEVEL=info

# =============================================================================
# THREAT INTELLIGENCE (optional)
# =============================================================================

THREAT_INTEL_URL=
EOF

chmod 600 "$OUTPUT"

echo "Generated ${OUTPUT} with fresh secrets."
echo ""
echo "  Mongo password : ${MONGO_ROOT_PASSWORD}"
echo "  Redis password : ${REDIS_PASSWORD}"
echo "  JWT secret     : ${JWT_SECRET}"
echo "  Admin password : ${ADMIN_PASSWORD}"
echo ""
echo "Remember to set YOUR_VPS_IP and YOUR_RASPI_IP before deploying."
