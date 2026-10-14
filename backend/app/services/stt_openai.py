import io

from openai import AsyncOpenAI

from app.core.config import settings
from app.services.stt_base import STTResult, STTService


class OpenAISTTService(STTService):
    """OpenAI Whisper STT implementation."""

    provider = "openai"

    def __init__(self):
        self.client = AsyncOpenAI(api_key=settings.openai_api_key)
        self.model = settings.stt_model

    async def transcribe(
        self,
        audio_data: bytes,
        language: str = "it",
        prompt: str | None = None,
        keyterms: list[str] | None = None,
    ) -> STTResult:
        """Transcribe PCM audio via OpenAI Whisper API.

        Args:
            audio_data: WAV audio bytes.
            language: Language hint for Whisper.
            prompt: Optional prompt to guide Whisper (improves accuracy with names,
                    jargon, and speaking style).
        """
        # Wrap raw PCM bytes in a WAV-like file object for the API
        audio_file = io.BytesIO(audio_data)
        audio_file.name = "audio.wav"

        # gpt-4o-transcribe only supports "json" or "text", not "verbose_json"
        is_whisper = self.model.startswith("whisper")
        response_format = "verbose_json" if is_whisper else "json"

        kwargs = {
            "model": self.model,
            "file": audio_file,
            "response_format": response_format,
        }
        if self.model.startswith(("gpt-transcribe", "gpt-live-transcribe")):
            # The newer models take a list of languages and reject the singular field
            kwargs["extra_body"] = {"languages": [language]}
        else:
            kwargs["language"] = language

        # Prompt improves accuracy by conditioning on expected vocabulary
        if prompt:
            kwargs["prompt"] = prompt

        response = await self.client.audio.transcriptions.create(**kwargs)

        return STTResult(
            text=response.text,
            language=language,
            confidence=None,
        )


def get_stt_service() -> STTService:
    """Factory function to get the configured STT service."""
    if settings.stt_provider == "openai":
        return OpenAISTTService()
    if settings.stt_provider == "deepgram":
        from app.services.stt_deepgram import DeepgramSTTService

        return DeepgramSTTService()
    raise ValueError(f"Unknown STT provider: {settings.stt_provider}")
