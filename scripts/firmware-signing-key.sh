#!/bin/bash
# =============================================================================
# Make the release key that signs wearable firmware, once: the wearable installs an update
# only signed with it, so neither the server nor a phone can install a firmware of its own.
#
# Usage: ./scripts/firmware-signing-key.sh
#   Writes the private key to firmware/signing/ota_private.pem (never committed: keep a
#   copy somewhere safe, offline) and its public half to firmware/src/ota_public_key.h,
#   which is committed and built into the firmware. Losing the private key means updates
#   go over the USB cable until a firmware with a new key is flashed that way.
#   OTA_SIGNING_KEY=path picks another place for the private key.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/../firmware"
key="${OTA_SIGNING_KEY:-signing/ota_private.pem}"
if [ -e "$key" ]; then
    echo "$key already exists: a new key would refuse every wearable's next update" >&2
    exit 1
fi
mkdir -p "$(dirname "$key")"
(umask 077 && openssl ecparam -name prime256v1 -genkey -noout -out "$key")

# The DER public key ends with the point's x and y, 32 bytes each
bytes="$(openssl ec -in "$key" -pubout -outform DER 2>/dev/null | tail -c 64 | od -An -v -tx1)"
{
    echo '#pragma once'
    echo
    echo '#include <cstdint>'
    echo
    echo '#include "ble_protocol.h"'
    echo
    echo '// The release key'"'"'s public half (x||y, P-256), from scripts/firmware-signing-key.sh:'
    echo '// an update is installed only signed with its private half (ota_signature.h)'
    echo 'static const uint8_t OTA_PUBLIC_KEY[EchoBleProtocol::OTA_PUBLIC_KEY_SIZE] = {'
    echo "$bytes" | tr -s ' \n' ' ' | sed 's/^ //; s/ $//' | tr ' ' '\n' \
        | sed 's/^/0x/' | paste -sd ',' | sed 's/,/, /g' | fold -w 80 -s | sed 's/^/    /; s/ *$//'
    echo '};'
} > src/ota_public_key.h
echo "Private key: firmware/$key (back it up). Public key: firmware/src/ota_public_key.h"
