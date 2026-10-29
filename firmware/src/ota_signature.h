#pragma once

#include <cstdint>

#include <uECC.h>

#include "ble_protocol.h"

/**
 * Whether `signature` (raw r||s) is the release key's ECDSA P-256 signature of `sha256`:
 * what `openssl dgst -sha256 -sign` gives over the image (scripts/firmware-release.sh).
 */
inline bool otaSignatureValid(const uint8_t* publicKey, const uint8_t* sha256,
                              const uint8_t* signature) {
    return uECC_verify(publicKey, sha256, EchoBleProtocol::SHA256_SIZE, signature,
                       uECC_secp256r1()) == 1;
}
