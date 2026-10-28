from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class STTResult:
    text: str
    # The language heard: one of the languages asked for, else the main one
    language: str
    confidence: float | None = None


def heard_language(detected: str | None, language: str, also: list[str] | None) -> str:
    """A detected language as its base code ("en-US" -> "en") when it is one of the
    account's; otherwise the main [language]."""
    code = (detected or "").split("-")[0].split("_")[0].lower()
    return code if code in [language, *(also or [])] else language


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
        also: list[str] | None = None,
    ) -> STTResult:
        """Transcribe audio data to text.

        Args:
            audio_data: WAV audio bytes (16kHz, 16bit, mono).
            language: ISO 639-1 language code.
            prompt: Optional conditioning prompt to improve accuracy
                    (e.g., frequently used names, jargon).
            keyterms: Names and terms to recognize, for providers that take a list
                    rather than a prompt. A provider uses what it supports.
            also: Other languages the user hears; with any, the provider recognises
                    which of [language, *also] is spoken where it can.

        Returns:
            STTResult with transcribed text.
        """
        ...
