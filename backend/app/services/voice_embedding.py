"""Voice fingerprint of a segment: a 256-number vector from a speaker-embedding model.

sherpa-onnx runs a WeSpeaker ResNet34 model (trained on VoxCeleb, which is multilingual)
on the CPU: ~2 s for a 5 s segment, run beside the transcription so it adds no delay.
Two segments of the same voice score a high cosine similarity, different voices a lower
one. Without the model file (e.g. outside Docker) fingerprints are simply skipped.
"""

import asyncio
import functools
import io
import logging
import math
import wave
from array import array
from pathlib import Path

from app.core.config import settings
from app.services.usage import record_usage, wav_seconds

logger = logging.getLogger(__name__)

DIMENSIONS = 256


def normalize(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(x * x for x in vector))
    return [x / norm for x in vector] if norm else list(vector)


def cosine(a, b) -> float:
    """Cosine similarity of two normalized vectors."""
    return float(sum(x * y for x, y in zip(a, b)))


class VoiceEmbedder:
    def __init__(self, model_path: str, num_threads: int = 2):
        import sherpa_onnx

        config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=model_path, num_threads=num_threads
        )
        self._extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
        if self._extractor.dim != DIMENSIONS:
            raise ValueError(f"Voice model gives {self._extractor.dim} numbers, not {DIMENSIONS}")

    def embed_wav(self, wav_bytes: bytes) -> list[float] | None:
        """The normalized fingerprint of 16-bit mono WAV audio; None if too short."""
        with wave.open(io.BytesIO(wav_bytes)) as wav:
            rate = wav.getframerate()
            if wav.getsampwidth() != 2 or wav.getnchannels() != 1:
                raise ValueError("expected 16-bit mono audio")
            frames = wav.readframes(wav.getnframes())
        samples = array("h")
        samples.frombytes(frames)
        if len(samples) < settings.voice_min_seconds * rate:
            return None
        stream = self._extractor.create_stream()
        stream.accept_waveform(rate, [s / 32768.0 for s in samples])
        stream.input_finished()
        return normalize(list(self._extractor.compute(stream)))


@functools.cache
def get_voice_embedder() -> VoiceEmbedder | None:
    """One per process (the model loads once); None when the model is not installed."""
    path = Path(settings.voice_model_path)
    if not path.is_file():
        logger.info("No voice model at %s: voice fingerprints are off", path)
        return None
    try:
        return VoiceEmbedder(str(path))
    except Exception:
        logger.exception("Could not load the voice model: voice fingerprints are off")
        return None


async def embed_voice(wav_bytes: bytes) -> list[float] | None:
    """The fingerprint, computed off the event loop; None when off, too short or failing."""
    embedder = get_voice_embedder()
    if embedder is None:
        return None
    try:
        vector = await asyncio.to_thread(embedder.embed_wav, wav_bytes)
        # Local and free: counted only to see the load it adds
        await record_usage("voice_embedding", "sherpa-onnx", input_units=wav_seconds(wav_bytes))
        return vector
    except Exception:
        logger.warning("Voice fingerprint failed", exc_info=True)
        return None
