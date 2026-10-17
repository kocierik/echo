#!/bin/bash
# =============================================================================
# Build the wearable firmware and publish it on the Echo server: the app then offers the
# update (Settings → Device details) and sends it to the wearable over Bluetooth.
#
# Usage: ./scripts/firmware-release.sh ["what changed"]
#   Run it where the server's containers run: it publishes inside the api container
#   (app/cli/firmware.py). There is no upload endpoint, so no key is needed and no account
#   can publish over the internet.
# The version comes from FIRMWARE_VERSION_* in firmware/src/config.h: raise it first.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/../firmware"
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

echo "Publishing $version..."
cd ..
docker compose exec -T api python -m app.cli.firmware publish \
    --version "$version" --notes "$notes" < "firmware/$image"
