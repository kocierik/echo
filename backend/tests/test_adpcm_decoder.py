"""Unit tests for ADPCM decoder."""

import io
import struct
import wave

from app.services.adpcm_decoder import adpcm_to_wav, decode_adpcm


class TestDecodeAdpcm:
    """Tests for ADPCM → PCM decoding."""

    def test_empty_input(self):
        """Empty ADPCM produces empty PCM."""
        result = decode_adpcm(b"")
        assert result == b""

    def test_silence_input(self):
        """All-zero ADPCM nibbles produce near-silence PCM."""
        # 100 bytes of zeros = 200 samples of silence
        adpcm_data = b"\x00" * 100
        pcm_data = decode_adpcm(adpcm_data)

        # Should produce 200 samples (400 bytes)
        assert len(pcm_data) == 400

        # All samples should be 0 or very close (silence)
        samples = struct.unpack(f"<{len(pcm_data) // 2}h", pcm_data)
        for sample in samples:
            assert abs(sample) < 10

    def test_output_length(self):
        """Each ADPCM byte produces 2 PCM samples (4 bytes)."""
        adpcm_data = b"\x12\x34\x56\x78\x9A"  # 5 bytes = 10 samples
        pcm_data = decode_adpcm(adpcm_data)
        assert len(pcm_data) == 10 * 2  # 10 samples * 2 bytes each

    def test_samples_in_range(self):
        """All decoded samples are within 16-bit signed range."""
        # Use varied ADPCM data
        adpcm_data = bytes(range(256)) * 4  # 1024 bytes
        pcm_data = decode_adpcm(adpcm_data)

        samples = struct.unpack(f"<{len(pcm_data) // 2}h", pcm_data)
        for sample in samples:
            assert -32768 <= sample <= 32767


class TestAdpcmToWav:
    """Tests for ADPCM → WAV conversion."""

    def test_produces_valid_wav(self):
        """Output is a valid WAV file."""
        adpcm_data = b"\x00\x11\x22\x33" * 50  # 200 bytes
        wav_data = adpcm_to_wav(adpcm_data)

        # Should start with RIFF header
        assert wav_data[:4] == b"RIFF"
        assert wav_data[8:12] == b"WAVE"

    def test_wav_properties(self):
        """WAV has correct sample rate, channels, and bit depth."""
        adpcm_data = b"\x55\xAA" * 100  # 200 bytes = 400 samples
        wav_data = adpcm_to_wav(adpcm_data)

        wav_buffer = io.BytesIO(wav_data)
        with wave.open(wav_buffer, "rb") as wav_file:
            assert wav_file.getnchannels() == 1       # Mono
            assert wav_file.getsampwidth() == 2       # 16-bit
            assert wav_file.getframerate() == 16000   # 16 kHz
            assert wav_file.getnframes() == 400       # 200 bytes * 2 samples/byte

    def test_roundtrip_preserves_length(self):
        """Number of output samples matches expected from input length."""
        input_bytes = 500
        adpcm_data = b"\x33" * input_bytes
        wav_data = adpcm_to_wav(adpcm_data)

        wav_buffer = io.BytesIO(wav_data)
        with wave.open(wav_buffer, "rb") as wav_file:
            # Each ADPCM byte → 2 samples
            expected_samples = input_bytes * 2
            assert wav_file.getnframes() == expected_samples
