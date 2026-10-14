"""Deepgram STT provider implementation.

Uses Deepgram's Nova-3 model for batch transcription.
Supports Italian and has very good accuracy on conversational audio.

Requires: DEEPGRAM_API_KEY env var.
"""

import httpx

from app.core.config import settings
from app.services.stt_base import STTResult, STTService

DEEPGRAM_API_URL = "https://api.deepgram.com/v1/listen"


class DeepgramSTTService(STTService):
    """Deepgram Nova STT implementation."""

    def __init__(self):
        self.api_key = settings.deepgram_api_key
        self.model = settings.deepgram_model

    async def transcribe(
        self, audio_data: bytes, language: str = "it", prompt: str | None = None
    ) -> STTResult:
        """Transcribe audio via Deepgram REST API.

        Args:
            audio_data: WAV audio bytes.
            language: Language code.
            prompt: Not used by Deepgram (no prompt support), ignored.
        """
        params = {
            "model": self.model,
            "language": language,
            "punctuate": "true",
            "smart_format": "true",
        }

        headers = {
            "Authorization": f"Token {self.api_key}",
            "Content-Type": "audio/wav",
        }

        async with httpx.AsyncClient(timeout=60.0) as client:
            response = await client.post(
                DEEPGRAM_API_URL,
                params=params,
                headers=headers,
                content=audio_data,
            )
            response.raise_for_status()

        data = response.json()

        # Extract transcript from Deepgram response
        channels = data.get("results", {}).get("channels", [])
        if not channels:
            return STTResult(text="", language=language, confidence=None)

        alternatives = channels[0].get("alternatives", [])
        if not alternatives:
            return STTResult(text="", language=language, confidence=None)

        best = alternatives[0]
        return STTResult(
            text=best.get("transcript", ""),
            language=language,
            confidence=best.get("confidence"),
        )
