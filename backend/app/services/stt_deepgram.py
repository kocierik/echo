"""Deepgram STT provider implementation.

Uses Deepgram's Nova-3 model for batch transcription.
Supports Italian and has very good accuracy on conversational audio.

Requires: DEEPGRAM_API_KEY env var.
"""

import httpx

from app.core.config import settings
from app.services.stt_base import STTResult, STTService

DEEPGRAM_API_URL = "https://api.deepgram.com/v1/listen"


# Deepgram's keyterm limit is 500 tokens per request; it advises 20-50 terms
MAX_KEYTERMS = 50


class DeepgramSTTService(STTService):
    """Deepgram Nova STT implementation."""

    provider = "deepgram"

    def __init__(self, transport: httpx.AsyncBaseTransport | None = None):
        self.api_key = settings.deepgram_api_key
        self.model = settings.deepgram_model
        self._transport = transport  # tests only

    async def transcribe(
        self,
        audio_data: bytes,
        language: str = "it",
        prompt: str | None = None,
        keyterms: list[str] | None = None,
    ) -> STTResult:
        """Transcribe audio via Deepgram REST API.

        Args:
            audio_data: WAV audio bytes.
            language: Language code.
            prompt: Not supported by Deepgram, ignored.
            keyterms: Sent as Nova-3 keyterm prompting (one `keyterm` parameter each).
        """
        params: list[tuple[str, str]] = [
            ("model", self.model),
            ("language", language),
            ("punctuate", "true"),
            ("smart_format", "true"),
        ]
        if self.model.startswith("nova-3"):
            params += [("keyterm", term) for term in (keyterms or [])[:MAX_KEYTERMS]]

        headers = {
            "Authorization": f"Token {self.api_key}",
            "Content-Type": "audio/wav",
        }

        async with httpx.AsyncClient(timeout=60.0, transport=self._transport) as client:
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
