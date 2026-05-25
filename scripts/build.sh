#!/bin/bash
# Build script that uses prebuilt binaries when available
# Usage: ./scripts/build.sh [service-name]
#
# Set PREBUILT_ONLY=true to skip local build entirely
# Set NETSENTRY_BUILD_LOCAL=true to force local build

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Architecture detection
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) TARGET="x86_64-unknown-linux-gnu"; SUFFIX="x86_64" ;;
    aarch64|arm64) TARGET="aarch64-unknown-linux-gnu"; SUFFIX="aarch64" ;;
    *) echo "Unknown architecture: $ARCH"; exit 1 ;;
esac

# Configuration
GITHUB_ORG="${GITHUB_ORG:-yourorg}"
REPO="netsentry-sensor"

# Services to build
EDGE_SERVICES=(
    "idps-packet-processor"
    "idps-network-filter"
    "idps-rule-engine"
    "raspi-collector"
    "idps-telemetry"
)

echo "=== NetSentry Build Script ==="
echo "Architecture: $TARGET"
echo "Build mode: $(if [[ "$NETSENTRY_BUILD_LOCAL" == "true" ]]; then echo "LOCAL (force)"; elif [[ "$PREBUILT_ONLY" == "true" ]]; then echo "PREBUILT ONLY"; else echo "AUTO (prebuilt preferred)"; fi)"
echo ""

# Create output directory
mkdir -p "$PROJECT_DIR/target/release"

download_prebuilt() {
    local binary="$1"
    echo "  Checking for prebuilt: $binary..."

    # Try GitHub releases
    local url="https://github.com/${GITHUB_ORG}/${REPO}/releases/latest/download/${binary}"
    local curl_result=$(curl -sfL "$url" -o "$PROJECT_DIR/target/release/$binary" 2>&1)

    if [[ -f "$PROJECT_DIR/target/release/$binary" ]]; then
        chmod +x "$PROJECT_DIR/target/release/$binary"
        echo "    ✓ Downloaded prebuilt: $binary"
        return 0
    fi

    # Try tagged releases
    local tags_url="https://api.github.com/repos/${GITHUB_ORG}/${REPO}/releases/tags/v*"
    # Fall back to building
    echo "    ✗ No prebuilt found"
    return 1
}

build_local() {
    local service="$1"
    echo "  Building locally: $service (this may take 10-15 minutes)..."
    cd "$PROJECT_DIR"
    cargo build --release -p "$service"
}

# Main build logic
main() {
    local target_service="${1:-}"

    if [[ -n "$target_service" ]]; then
        EDGE_SERVICES=("$target_service")
    fi

    for service in "${EDGE_SERVICES[@]}"; do
        echo "[*] Processing: $service"

        # Try prebuilt first (unless NETSENTRY_BUILD_LOCAL is set)
        if [[ "$NETSENTRY_BUILD_LOCAL" != "true" ]]; then
            if download_prebuilt "$service"; then
                continue
            fi
        fi

        # Fall back to local build
        build_local "$service"
    done

    echo ""
    echo "=== Build Complete ==="
    ls -la "$PROJECT_DIR/target/release/" | grep -E "idps-|raspi-"
}

main "$@"
