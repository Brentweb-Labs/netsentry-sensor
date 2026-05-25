#!/bin/bash
# Bridge container entrypoint
# Sets up network bridging for IDPS sensor

set -e

echo "Starting bridge setup..."

# Wait for network
sleep 2

# Check if we should run in span mode or inline mode
MODE="${BRIDGE_MODE:-inline}"

case "$MODE" in
    span)
        echo "Configuring SPAN port mode..."
        # SPAN port mirroring
        ;;
    inline)
        echo "Configuring inline bridging mode..."
        # Inline bridge setup
        ;;
    *)
        echo "Unknown mode: $MODE"
        exit 1
        ;;
esac

echo "Bridge ready"

# Keep container running
exec tail -f /dev/null
