"""Deepgram STT provider implementation.

Uses Deepgram's Nova-3 model for batch transcription.
Supports Italian and has very good accuracy on conversational audio.

Requires: DEEPGRAM_API_KEY env var.
"""

import httpx

from app.core.config import settings
from app.services.stt_base import STTResult, STTService, Word, heard_language
from app.services.usage import record_usage, wav_seconds

DEEPGRAM_API_URL = "https://api.deepgram.com/v1/listen"


# Deepgram's keyterm limit is 500 tokens per request; it advises 20-50 terms
MAX_KEYTERMS = 50
# The languages Nova-3 follows switching within a sentence (language=multi)
MULTILINGUAL = {"de", "en", "es", "fr", "hi", "it", "ja", "nl", "pt", "ru"}


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
        also: list[str] | None = None,
        diarize: bool = False,
    ) -> STTResult:
        """Transcribe audio via Deepgram REST API.

        Args:
            audio_data: WAV audio bytes.
            language: Language code.
            prompt: Not supported by Deepgram, ignored.
            keyterms: Sent as Nova-3 keyterm prompting (one `keyterm` parameter each).
            also: Other languages heard: Deepgram then detects among [language, *also]
                (one `detect_language` each) instead of being told the language.
            diarize: Each word with its speaker (0, 1, ...).
        """
        detecting = bool(also)
        params: list[tuple[str, str]] = [("model", self.model)]
        if detecting and self.model.startswith("nova-3") and {language, *also} <= MULTILINGUAL:
            # One language per word, not per segment: "Ho detto since five years" whole
            params.append(("language", "multi"))
        elif detecting:
            params += [("detect_language", code) for code in [language, *also]]
        else:
            params.append(("language", language))
        params += [("punctuate", "true"), ("smart_format", "true")]
        if diarize:
            params.append(("diarize", "true"))
        terms: list[tuple[str, str]] = []
        if self.model.startswith("nova-3"):
            terms = [("keyterm", term) for term in (keyterms or [])[:MAX_KEYTERMS]]

        headers = {
            "Authorization": f"Token {self.api_key}",
            "Content-Type": "audio/wav",
        }

        async with httpx.AsyncClient(timeout=60.0, transport=self._transport) as client:
            response = await client.post(
                DEEPGRAM_API_URL,
                params=params + terms,
                headers=headers,
                content=audio_data,
            )
            if response.status_code == 400 and detecting and terms:
                # Keyterms may not go with detection: once more without them
                response = await client.post(
                    DEEPGRAM_API_URL,
                    params=params,
                    headers=headers,
                    content=audio_data,
                )
            response.raise_for_status()
        await record_usage("stt", self.model, input_units=wav_seconds(audio_data))

        data = response.json()

        # Extract transcript from Deepgram response
        channels = data.get("results", {}).get("channels", [])
        if not channels:
            return STTResult(text="", language=language, confidence=None)

        alternatives = channels[0].get("alternatives", [])
        # Detection names one language; multilingual lists those heard, the most first
        spoken = (alternatives[0].get("languages") or [None])[0] if alternatives else None
        heard = heard_language(
            channels[0].get("detected_language") or spoken, language, also
        )
        if not alternatives:
            return STTResult(text="", language=heard, confidence=None)

        best = alternatives[0]
        return STTResult(
            text=best.get("transcript", ""),
            language=heard,
            confidence=best.get("confidence"),
            words=[
                Word(
                    w.get("punctuated_word") or w["word"], float(w["start"]), float(w["end"]),
                    w.get("speaker"),
                )
                for w in best.get("words", [])
                if w.get("word") is not None and "start" in w and "end" in w
            ],
        )
