#!/bin/bash
# =============================================================================
# Build the wearable firmware and publish it on the Echo server: the app then offers the
# update (Settings → Device details) and sends it to the wearable over Bluetooth.
#
# Usage: ./scripts/firmware-release.sh ["what changed"]
#   Run it where the server's containers run: it publishes inside the api container
#   (app/cli/firmware.py). There is no upload endpoint, so no account can publish over the
#   internet. The image is signed with the release key (scripts/firmware-signing-key.sh,
#   firmware/signing/ota_private.pem or OTA_SIGNING_KEY=path): the wearable installs nothing
#   else. Kept off the server, the key also stops whoever controls the server.
# The version comes from FIRMWARE_VERSION_* in firmware/src/config.h: raise it first.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/../firmware"
notes="${1:-}"
key="${OTA_SIGNING_KEY:-signing/ota_private.pem}"
if [ ! -r "$key" ]; then
    echo "No release key at firmware/$key: the wearable would refuse the update." >&2
    echo "Point OTA_SIGNING_KEY at it, or make one with scripts/firmware-signing-key.sh." >&2
    exit 1
fi

part() { awk -v name="FIRMWARE_VERSION_$1" '$1 == "#define" && $2 == name { print $3 }' src/config.h; }
version="$(part MAJOR).$(part MINOR).$(part PATCH)"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Could not read FIRMWARE_VERSION_* from firmware/src/config.h" >&2
    exit 1
fi

echo "Building firmware $version..."
if command -v pio >/dev/null; then
    pio run -e xiao_esp32s3
else
    # No PlatformIO here (the server): the same build in a container, its toolchain cached
    docker run --rm -v echo-pio-cache:/root/.platformio -v "$PWD:/fw" -w /fw python:3.11 sh -c \
        "pip install -q platformio >/dev/null && pio run -e xiao_esp32s3; status=\$?; chown -R $(id -u):$(id -g) .pio; exit \$status"
fi
image=.pio/build/xiao_esp32s3/firmware.bin
signature="$(openssl dgst -sha256 -sign "$key" "$image" | od -An -v -tx1 | tr -d ' 
')"

echo "Publishing $version..."
cd ..
docker compose exec -T api python -m app.cli.firmware publish \
    --version "$version" --signature "$signature" --notes "$notes" < "firmware/$image"
