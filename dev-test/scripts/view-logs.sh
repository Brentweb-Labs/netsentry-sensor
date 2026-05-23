#!/bin/bash
# =============================================================================
# Log Viewer: Tail Suricata eve.json
# =============================================================================
# This script watches the Suricata eve.json output for real-time alerts.
# The output is formatted with jq for readability.
#
# Usage (from host):
#   ./view-logs.sh              # Watch live alerts
#   ./view-logs.sh --count=10   # Show last 10 alerts
#   ./view-logs.sh --alerts     # Show only alerts
# =============================================================================

set -e

# Configuration
EVE_JSON_PATH="${EVE_JSON_PATH:-./data/logs/suricata/eve.json}"

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "[!] jq not found. Installing..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get install -y jq
    elif command -v brew &> /dev/null; then
        brew install jq
    else
        echo "[!] Cannot install jq. Using basic cat."
        JQ_AVAILABLE=false
    fi
else
    JQ_AVAILABLE=true
fi

# Parse arguments
case "${1:-}" in
    --count=*)
        COUNT="${1#*=}"
        if [ "$JQ_AVAILABLE" = true ]; then
            tail -n 500 "$EVE_JSON_PATH" 2>/dev/null | grep -v '^$' | tail -n "$COUNT" | jq -c '.' 2>/dev/null || cat "$EVE_JSON_PATH" | tail -n "$COUNT"
        else
            tail -n "$COUNT" "$EVE_JSON_PATH" 2>/dev/null || echo "[!] No logs yet. Wait for attacks to generate events."
        fi
        ;;
    --alerts)
        echo "[*] Showing only ALERT events..."
        if [ "$JQ_AVAILABLE" = true ]; then
            tail -f "$EVE_JSON_PATH" 2>/dev/null | grep '"alert"' | jq -c '{timestamp: .timestamp, src_ip: .src_ip, dest_ip: .dest_ip, alert: .alert.signature, category: .alert.category, severity: .alert.severity}' 2>/dev/null || true
        else
            tail -f "$EVE_JSON_PATH" | grep '"alert"' || true
        fi
        ;;
    --stats)
        echo "[*] Showing stats events..."
        if [ "$JPG_AVAILABLE" = true ]; then
            tail -f "$EVE_JSON_PATH" | grep '"stats"' | jq '{timestamp: .timestamp, stats: .stats}' || true
        else
            tail -f "$EVE_JSON_PATH" | grep '"stats"' || true
        fi
        ;;
    -h|--help|*)
        echo "Usage: $0 [option]"
        echo ""
        echo "Options:"
        echo "  (none)           Watch live eve.json output (formatted)"
        echo "  --count=N        Show last N events"
        echo "  --alerts         Watch only alert events"
        echo "  --stats          Watch only stats events"
        echo "  -h, --help       Show this help"
        echo ""
        echo "Examples:"
        echo "  $0                # Live monitoring"
        echo "  $0 --count=10     # Last 10 events"
        echo "  $0 --alerts       # Only alerts"
        exit 0
        ;;
esac

# Default: tail with jq formatting
if [ "$JQ_AVAILABLE" = true ]; then
    echo "[*] Streaming eve.json with jq formatting..."
    echo "[*] Press Ctrl+C to stop"
    echo ""
    tail -f "$EVE_JSON_PATH" 2>/dev/null | while read -r line; do
        if [ -n "$line" ]; then
            echo "$line" | jq -c '.timestamp, .event_type, .src_ip, .dest_ip, .alert.signature // .app_proto // .incomplete // .type' 2>/dev/null || true
        fi
    done
else
    echo "[*] Streaming raw eve.json (jq not available)..."
    tail -f "$EVE_JSON_PATH" 2>/dev/null || echo "[!] No logs yet."
fi
