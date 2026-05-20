#!/bin/bash

# Quick check for eve.json status on Raspberry Pi

echo "🔍 Checking eve.json status..."

EVE_JSON_PATH="/home/brent/idps/data/logs/suricata/eve.json"

if [ -f "$EVE_JSON_PATH" ]; then
    FILE_SIZE=$(du -h "$EVE_JSON_PATH" | cut -f1)
    LINE_COUNT=$(wc -l < "$EVE_JSON_PATH" 2>/dev/null || echo "0")
    
    echo "✅ eve.json exists!"
    echo "  Location: $EVE_JSON_PATH"
    echo "  Size: $FILE_SIZE"
    echo "  Lines: $LINE_COUNT"
    
    if [ "$LINE_COUNT" -gt 0 ]; then
        echo ""
        echo "=== Latest Events ==="
        tail -3 "$EVE_JSON_PATH"
        echo ""
        
        # Count event types
        ALERT_COUNT=$(grep -c '"event_type":"alert"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        DNS_COUNT=$(grep -c '"event_type":"dns"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        HTTP_COUNT=$(grep -c '"event_type":"http"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        ICMP_COUNT=$(grep -c '"event_type":"icmp"' "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        
        echo "=== Event Summary ==="
        echo "  Alerts: $ALERT_COUNT"
        echo "  DNS: $DNS_COUNT"
        echo "  HTTP: $HTTP_COUNT"
        echo "  ICMP: $ICMP_COUNT"
        
        echo ""
        echo "🎉 SUCCESS: eve.json is being generated!"
        echo "Your IDPS is working and detecting network traffic."
    else
        echo "⚠️ eve.json exists but is empty"
        echo "Generating test traffic..."
        ping -c 3 8.8.8.8 >/dev/null 2>&1 &
        sleep 5
        
        NEW_LINE_COUNT=$(wc -l < "$EVE_JSON_PATH" 2>/dev/null || echo "0")
        if [ "$NEW_LINE_COUNT" -gt 0 ]; then
            echo "✅ Now has $NEW_LINE_COUNT lines of events!"
        else
            echo "❌ Still empty - check Suricata status"
        fi
    fi
else
    echo "❌ eve.json does not exist"
    echo "Expected location: $EVE_JSON_PATH"
    echo ""
    echo "Check Suricata container:"
    docker ps | grep suricata
    echo ""
    echo "Run the fix script:"
    echo "sudo ./scripts/fix-eve-json-raspi.sh"
fi
