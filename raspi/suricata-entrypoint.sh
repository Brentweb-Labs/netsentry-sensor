#!/bin/sh
# Suricata startup: update ET Open rules, then start Suricata.
# Runs suricata-update only when rules are missing or older than 24 hours.
set -e

RULES_DIR="/var/lib/suricata/rules"
COMBINED_RULES="$RULES_DIR/suricata.rules"

mkdir -p "$RULES_DIR"

# Download / refresh ET Open rules
if [ ! -f "$COMBINED_RULES" ] || \
   [ "$(find "$COMBINED_RULES" -mmin +1440 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "[suricata-init] Updating rules via suricata-update (ET Open)..."
    suricata-update \
        --no-reload \
        --output "$RULES_DIR" \
        2>&1 || echo "[suricata-init] suricata-update failed — starting with existing rules"
    echo "[suricata-init] Rules update complete."
else
    echo "[suricata-init] Rules are up-to-date (< 24h old), skipping update."
fi

# Ensure the dynamic rules file exists so Suricata won't fail on missing file
touch "$RULES_DIR/idps-dynamic.rules"

IFACE="${SURICATA_IFACE:-eth0}"
echo "[suricata-init] Starting Suricata on interface $IFACE..."
exec suricata -c /etc/suricata/suricata.yaml -i "$IFACE"
