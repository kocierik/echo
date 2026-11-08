"""The wearable's speech, ADPCM (firmware up to 0.8) or Opus (0.9 on), as PCM."""

import math
import struct

import pytest

from app.services.adpcm_decoder import decode_adpcm
from app.services.segment_audio import FRAME_SAMPLES, MAGIC, decode_segment, segment_to_wav

opuslib = pytest.importorskip("opuslib")


def _tone(frames: int) -> list[bytes]:
    """`frames` frames of 20 ms of a 440 Hz tone, as 16-bit PCM."""
    out = []
    for f in range(frames):
        samples = [
            int(8000 * math.sin(2 * math.pi * 440 * (f * FRAME_SAMPLES + i) / 16000))
            for i in range(FRAME_SAMPLES)
        ]
        out.append(struct.pack(f"<{FRAME_SAMPLES}h", *samples))
    return out


def _opus_segment(frames: int) -> bytes:
    """As firmware/src/opus_segment.h writes it: MAGIC, then a length byte per packet."""
    encoder = opuslib.Encoder(16000, 1, opuslib.APPLICATION_VOIP)
    encoder.bitrate = 16000
    data = bytearray(MAGIC)
    for pcm in _tone(frames):
        packet = encoder.encode(pcm, FRAME_SAMPLES)
        data += bytes([len(packet)]) + packet
    return bytes(data)


def test_an_opus_segment_is_decoded_to_its_length():
    segment = _opus_segment(50)  # one second

    pcm = decode_segment(segment)

    assert len(pcm) == 50 * FRAME_SAMPLES * 2
    # About a fifth of the ADPCM's 8 KB a second
    assert len(segment) < 3000
    # Sound, not silence
    samples = struct.unpack(f"<{len(pcm) // 2}h", pcm)
    assert max(abs(s) for s in samples[FRAME_SAMPLES * 5:]) > 2000


def test_a_segment_cut_short_keeps_what_arrived_whole():
    segment = _opus_segment(10)

    pcm = decode_segment(segment[:-3])

    assert len(pcm) == 9 * FRAME_SAMPLES * 2


def test_adpcm_is_decoded_as_before():
    adpcm = bytes(range(256)) * 4

    assert decode_segment(adpcm) == decode_adpcm(adpcm)
    assert segment_to_wav(adpcm).startswith(b"RIFF")
