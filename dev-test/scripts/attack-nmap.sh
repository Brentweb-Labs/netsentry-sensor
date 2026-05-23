#!/bin/bash
# =============================================================================
# Attack Script 1: Nmap Aggressive Scan
# =============================================================================
# This script runs an aggressive nmap scan that will trigger Suricata's
# default ET Open rules for port scanning and OS detection.
#
# Usage (from attacker container):
#   ./attack-scripts/attack-nmap.sh
#
# Or from host:
#   docker compose -f docker-compose.yml exec attacker /attack-scripts/attack-nmap.sh
# =============================================================================

set -e

# Configuration
VICTIM_IP="${VICTIM_IP:-10.10.10.4}"
SURICATA_IP="${SURICATA_IP:-10.10.10.3}"

echo "[*] ================================================"
echo "[*] NetSentry IDPS Test - Nmap Aggressive Scan"
echo "[*] ================================================"
echo "[*] Target: $VICTIM_IP"
echo "[*] Sensor: $SURICATA_IP"
echo "[*] ================================================"

# Check connectivity first
echo "[*] Verifying connectivity to victim..."
ping -c 2 "$VICTIM_IP" || echo "[!] Warning: ping failed, continuing anyway..."

# Run aggressive nmap scan
# -A: Enable OS detection and version detection
# -T4: Aggressive timing
# -p-: Scan all ports
# This will trigger multiple Suricata rules for port scanning
echo "[*] Running aggressive nmap scan..."
nmap -A -T4 -p- -v "$VICTIM_IP" 2>&1 | head -100

# Additional aggressive scans
echo "[*] Running OSDetection scan..."
nmap -O -T4 "$VICTIM_IP" 2>&1 | head -50

echo "[*] Running version detection scan..."
nmap -sV -T4 "$VICTIM_IP" 2>&1 | head -50

echo ""
echo "[*] ================================================"
echo "[*] Scan complete. Check Suricata eve.json for alerts."
echo "[*] Expected alerts:"
echo "[*]   - ET SCAN nmap"
echo "[*]   - ET OS Intentional nmap"
echo "[*]   - ET SCAN Port Scan"
echo "[*] ================================================"
