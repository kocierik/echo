from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class STTResult:
    text: str
    language: str
    confidence: float | None = None


class STTService(ABC):
    """Abstract interface for Speech-to-Text services."""

    # What a transcription records as its origin: the service that actually ran
    provider: str
    model: str

    @abstractmethod
    async def transcribe(
        self,
        audio_data: bytes,
        language: str = "it",
        prompt: str | None = None,
        keyterms: list[str] | None = None,
    ) -> STTResult:
        """Transcribe audio data to text.

        Args:
            audio_data: WAV audio bytes (16kHz, 16bit, mono).
            language: ISO 639-1 language code.
            prompt: Optional conditioning prompt to improve accuracy
                    (e.g., frequently used names, jargon).
            keyterms: Names and terms to recognize, for providers that take a list
                    rather than a prompt. A provider uses what it supports.

        Returns:
            STTResult with transcribed text.
        """
        ...
