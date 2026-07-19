from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class STTResult:
    text: str
    language: str
    confidence: float | None = None


class STTService(ABC):
    """Abstract interface for Speech-to-Text services."""

    @abstractmethod
    async def transcribe(self, audio_data: bytes, language: str = "it") -> STTResult:
        """Transcribe audio data to text.

        Args:
            audio_data: Raw PCM audio bytes (16kHz, 16bit, mono).
            language: ISO 639-1 language code.

        Returns:
            STTResult with transcribed text.
        """
        ...
