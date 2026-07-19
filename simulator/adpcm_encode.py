"""IMA-ADPCM encoder — compatible with the ESP32-S3 firmware encoder and backend decoder."""

import struct

# Same tables as firmware (adpcm_encoder.h) and backend (adpcm_decoder.py)
STEP_TABLE = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
]

INDEX_TABLE = [
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8,
]


def encode_adpcm(pcm_data: bytes) -> bytes:
    """Encode 16-bit signed PCM to IMA-ADPCM.

    Args:
        pcm_data: Raw PCM bytes (16-bit signed little-endian, mono, 16kHz).

    Returns:
        ADPCM encoded bytes (4-bit nibbles packed, low nibble first).
    """
    samples = struct.unpack(f"<{len(pcm_data) // 2}h", pcm_data)
    return encode_adpcm_samples(samples)


def encode_adpcm_samples(samples: list | tuple) -> bytes:
    """Encode a sequence of 16-bit PCM samples to IMA-ADPCM.

    Args:
        samples: Sequence of int16 PCM samples.

    Returns:
        ADPCM encoded bytes.
    """
    prev_sample: int = 0
    index: int = 0
    adpcm_bytes = bytearray()

    for i in range(0, len(samples), 2):
        byte = 0

        for j in range(2):
            if i + j >= len(samples):
                break

            sample = samples[i + j]

            # Calculate difference
            diff = sample - prev_sample
            nibble = 0

            if diff < 0:
                nibble = 8
                diff = -diff

            step = STEP_TABLE[index]

            # Quantize
            if diff >= step:
                nibble |= 4
                diff -= step
            if diff >= step >> 1:
                nibble |= 2
                diff -= step >> 1
            if diff >= step >> 2:
                nibble |= 1

            # Reconstruct for predictor update
            diffq = STEP_TABLE[index] >> 3
            if nibble & 4:
                diffq += STEP_TABLE[index]
            if nibble & 2:
                diffq += STEP_TABLE[index] >> 1
            if nibble & 1:
                diffq += STEP_TABLE[index] >> 2

            if nibble & 8:
                prev_sample -= diffq
            else:
                prev_sample += diffq

            # Clamp
            prev_sample = max(-32768, min(32767, prev_sample))

            # Update index
            index += INDEX_TABLE[nibble]
            index = max(0, min(88, index))

            # Pack nibble
            if j == 0:
                byte = nibble & 0x0F
            else:
                byte |= (nibble & 0x0F) << 4

        adpcm_bytes.append(byte)

    return bytes(adpcm_bytes)
