"""The wearable's speech as PCM (16 kHz, 16-bit, mono), whichever codec it came in.

Up to firmware 0.8 a segment is IMA-ADPCM (8 KB a second). From 0.9 it is Opus at
16 kbit/s (about a quarter of that): the segment starts with MAGIC, then each 20 ms packet
as one byte of length and its bytes (firmware/src/opus_segment.h). Nothing else changed
on the way: the app forwards the bytes as they are.
"""

import io
import wave

from app.services.adpcm_decoder import CHANNELS, SAMPLE_RATE, SAMPLE_WIDTH, decode_adpcm

MAGIC = b"EOP1"
# 20 ms at 16 kHz: the frame every packet holds
FRAME_SAMPLES = 320


def decode_segment(data: bytes) -> bytes:
    """A segment's audio as PCM: Opus when it starts with MAGIC, else ADPCM."""
    if not data.startswith(MAGIC):
        return decode_adpcm(data)
    import opuslib  # loads the system's libopus: only when an Opus segment comes

    decoder = opuslib.Decoder(SAMPLE_RATE, CHANNELS)
    pcm = bytearray()
    position = len(MAGIC)
    while position < len(data):
        size = data[position]
        packet = data[position + 1:position + 1 + size]
        position += 1 + size
        if len(packet) < size:
            break  # a segment cut short: what arrived whole
        pcm += decoder.decode(packet, FRAME_SAMPLES)
    return bytes(pcm)


def pcm_to_wav(pcm: bytes) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(CHANNELS)
        wav.setsampwidth(SAMPLE_WIDTH)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm)
    return buffer.getvalue()


def segment_to_wav(data: bytes) -> bytes:
    """A segment as a WAV file, for the speech-to-text and the voice fingerprint."""
    return pcm_to_wav(decode_segment(data))
