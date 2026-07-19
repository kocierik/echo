"""ADPCM decoder: converts IMA-ADPCM audio to PCM WAV for STT processing."""

import io
import struct
import wave

# IMA-ADPCM step table
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

# Index adjustment table
INDEX_TABLE = [
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8,
]

SAMPLE_RATE = 16000
CHANNELS = 1
SAMPLE_WIDTH = 2  # 16-bit


def decode_adpcm(adpcm_data: bytes) -> bytes:
    """Decode IMA-ADPCM bytes to raw PCM samples (16-bit signed, little-endian).

    Args:
        adpcm_data: Raw ADPCM bytes (4-bit nibbles packed in bytes, low nibble first).

    Returns:
        Raw PCM bytes (16-bit signed, mono, 16kHz).
    """
    prev_sample: int = 0
    index: int = 0
    pcm_samples: list[int] = []

    for byte in adpcm_data:
        # Low nibble first (matches encoder: low nibble = first sample)
        for nibble in (byte & 0x0F, (byte >> 4) & 0x0F):
            step = STEP_TABLE[index]

            # Reconstruct difference
            diff = step >> 3
            if nibble & 4:
                diff += step
            if nibble & 2:
                diff += step >> 1
            if nibble & 1:
                diff += step >> 2

            # Apply sign
            if nibble & 8:
                prev_sample -= diff
            else:
                prev_sample += diff

            # Clamp to 16-bit range
            prev_sample = max(-32768, min(32767, prev_sample))
            pcm_samples.append(prev_sample)

            # Update index
            index += INDEX_TABLE[nibble]
            index = max(0, min(88, index))

    return struct.pack(f"<{len(pcm_samples)}h", *pcm_samples)


def adpcm_to_wav(adpcm_data: bytes) -> bytes:
    """Convert IMA-ADPCM audio to a WAV file in memory.

    Args:
        adpcm_data: Raw ADPCM bytes from the device.

    Returns:
        Complete WAV file bytes (16kHz, 16-bit, mono PCM).
    """
    pcm_data = decode_adpcm(adpcm_data)

    wav_buffer = io.BytesIO()
    with wave.open(wav_buffer, "wb") as wav_file:
        wav_file.setnchannels(CHANNELS)
        wav_file.setsampwidth(SAMPLE_WIDTH)
        wav_file.setframerate(SAMPLE_RATE)
        wav_file.writeframes(pcm_data)

    return wav_buffer.getvalue()
