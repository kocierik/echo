"""Echo's natural voices for spoken answers (Profile → Spoken answers → Voice), on the plans
that have them (`premium_voice`): the phone sends the answer's text as it would read it
aloud and plays the audio back. Without the plan, or when this fails, the phone's own
voice reads it. OpenAI's gpt-4o-mini-tts; its cost is counted as seconds of audio estimated
from the text (usage_prices.py).
"""

import logging

from app.core.config import settings
from app.services.usage import record_usage

logger = logging.getLogger(__name__)

MODEL = "gpt-4o-mini-tts"
# The answer as read aloud is cut near 500 characters on the phone: room for that
MAX_CHARS = 1200
# About how fast these voices speak, to count the audio's seconds from the text
CHARS_PER_SECOND = 15

# The voices offered, by name: what each sounds like, for the picker
VOICES = {
    "coral": "Warm and bright",
    "nova": "Clear and friendly",
    "shimmer": "Soft and calm",
    "sage": "Calm and steady",
    "ash": "Deep and relaxed",
    "ballad": "Gentle and expressive",
}
DEFAULT_VOICE = "coral"

INSTRUCTIONS = (
    "You are Echo, a personal assistant, reading an answer aloud to the user. Speak "
    "naturally, warmly and calmly, at a relaxed pace, in the language of the text."
)
# Without it these voices read Italian with an English accent
ACCENTS = {
    "it": "Speak Italian as a native speaker from Italy, with a natural Italian accent and "
    "Italian pronunciation of every word; never an English accent.",
    "en": "Speak English as a native speaker, with a natural accent.",
}


def instructions_for(language: str | None) -> str:
    accent = ACCENTS.get(language or "")
    return f"{INSTRUCTIONS} {accent}" if accent else INSTRUCTIONS


class SpeechError(Exception):
    pass


class OpenAISpeech:
    def __init__(self, client=None):
        if client is None:
            from openai import AsyncOpenAI

            client = AsyncOpenAI(api_key=settings.openai_api_key)
        self._client = client

    async def speak(self, text: str, voice: str, language: str | None = None) -> bytes:
        """The text as MP3 audio, spoken as a native of `language` when it is given."""
        try:
            response = await self._client.audio.speech.create(
                model=MODEL, voice=voice, input=text, instructions=instructions_for(language),
                response_format="mp3",
            )
            audio = response.content
        except Exception as exc:
            logger.warning("Could not make a spoken answer", exc_info=True)
            raise SpeechError("The voice could not be made now") from exc
        await record_usage(
            "tts", MODEL, input_units=max(1, round(len(text) / CHARS_PER_SECOND)),
        )
        return audio


def voice_or_default(voice: str | None) -> str:
    return voice if voice in VOICES else DEFAULT_VOICE


def get_speech() -> OpenAISpeech:
    return OpenAISpeech()
