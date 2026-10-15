#!/bin/bash
# =============================================================================
# Build the wearable firmware and publish it to the Echo server: the app then offers
# the update (Settings → Device) and sends it to the wearable over Bluetooth.
#
# Usage: ECHO_API_KEY=... ./scripts/firmware-release.sh ["what changed"]
#   ECHO_URL defaults to this Mac's server (http://localhost:8000).
# The version comes from FIRMWARE_VERSION_* in firmware/src/config.h: raise it first.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/../firmware"

if [ -z "${ECHO_API_KEY:-}" ]; then
    echo "Set ECHO_API_KEY to your Echo API key (the one the app uses)." >&2
    exit 1
fi
url="${ECHO_URL:-http://localhost:8000}"
notes="${1:-}"

part() { awk -v name="FIRMWARE_VERSION_$1" '$1 == "#define" && $2 == name { print $3 }' src/config.h; }
version="$(part MAJOR).$(part MINOR).$(part PATCH)"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Could not read FIRMWARE_VERSION_* from firmware/src/config.h" >&2
    exit 1
fi

echo "Building firmware $version..."
pio run -e xiao_esp32s3
image=.pio/build/xiao_esp32s3/firmware.bin

echo "Publishing $version to $url..."
response=$(curl -sS -w '\n%{http_code}' -X POST \
    -H "X-API-Key: $ECHO_API_KEY" \
    --form-string "version=$version" \
    --form-string "notes=$notes" \
    -F "image=@$image;type=application/octet-stream" \
    "$url/api/firmware")
status=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
case "$status" in
    201) echo "Published $version: the app will offer it." ;;
    200) echo "$version was already published with this same image." ;;
    *) echo "Publishing failed ($status): $body" >&2; exit 1 ;;
esac
