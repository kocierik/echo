"""Speech-to-text services: each records what it is and uses the hints it supports."""

from types import SimpleNamespace

import httpx
import pytest

from app.core.config import settings
from app.services import stt_openai
from app.services.stt_deepgram import MAX_KEYTERMS, DeepgramSTTService
from app.services.stt_openai import OpenAISTTService
from app.services.transcription_enhancer import build_stt_context
from tests.factories import make_conversation, make_entity

_DEEPGRAM_OK = {
    "results": {
        "channels": [{"alternatives": [{"transcript": "Ciao Marco", "confidence": 0.93}]}]
    }
}


def _deepgram(monkeypatch, model: str, seen: list[httpx.Request]) -> DeepgramSTTService:
    monkeypatch.setattr(settings, "deepgram_model", model)

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=_DEEPGRAM_OK)

    return DeepgramSTTService(transport=httpx.MockTransport(handler))


@pytest.mark.asyncio
async def test_deepgram_nova3_sends_one_keyterm_parameter_per_term(monkeypatch):
    seen: list[httpx.Request] = []
    service = _deepgram(monkeypatch, "nova-3", seen)

    result = await service.transcribe(
        b"wav", language="it", prompt="ignored", keyterms=["Marco Rossi", "Atlas"]
    )

    params = seen[0].url.params
    assert params.get_list("keyterm") == ["Marco Rossi", "Atlas"]
    assert params["language"] == "it"
    assert "prompt" not in params
    assert result.text == "Ciao Marco"
    assert (service.provider, service.model) == ("deepgram", "nova-3")


@pytest.mark.asyncio
async def test_deepgram_caps_keyterms_and_skips_them_before_nova3(monkeypatch):
    seen: list[httpx.Request] = []
    nova3 = _deepgram(monkeypatch, "nova-3", seen)
    await nova3.transcribe(b"wav", keyterms=[f"term{i}" for i in range(80)])
    nova2 = _deepgram(monkeypatch, "nova-2", seen)
    await nova2.transcribe(b"wav", keyterms=["Marco"])

    assert len(seen[0].url.params.get_list("keyterm")) == MAX_KEYTERMS
    assert seen[1].url.params.get_list("keyterm") == []


@pytest.mark.asyncio
async def test_openai_uses_the_prompt_and_names_its_model(monkeypatch):
    calls = []

    class _Transcriptions:
        async def create(self, **kwargs):
            calls.append(kwargs)
            return SimpleNamespace(text="Ciao Marco")

    class _Client:
        def __init__(self, api_key):
            self.audio = SimpleNamespace(transcriptions=_Transcriptions())

    monkeypatch.setattr(stt_openai, "AsyncOpenAI", _Client)
    monkeypatch.setattr(settings, "stt_model", "gpt-4o-transcribe")
    service = OpenAISTTService()

    await service.transcribe(b"wav", prompt="Ho parlato con Marco.", keyterms=["Marco"])

    assert calls[0]["prompt"] == "Ho parlato con Marco."
    assert "keyterms" not in calls[0]
    assert (service.provider, service.model) == ("openai", "gpt-4o-transcribe")


@pytest.mark.asyncio
async def test_context_has_a_prompt_and_short_unique_keyterms(db_session):
    from datetime import datetime, timezone

    from tests.conftest import TEST_USER_ID

    conversation, _ = await make_conversation(db_session, started_at=datetime.now(timezone.utc))
    db_session.add_all(
        [
            make_entity(conversation, "person", "Marco Rossi"),
            make_entity(conversation, "person", "marco rossi"),  # same name
            make_entity(conversation, "idea", "Atlas"),
            make_entity(conversation, "task", "Mandare a Marco il budget di Atlas"),  # a sentence
        ]
    )
    await db_session.commit()

    context = await build_stt_context(db_session, TEST_USER_ID)

    assert "Marco Rossi" in context.prompt
    # One Marco however it was written; the sentence-long task name is left out
    assert sorted(term.lower() for term in context.keyterms) == ["atlas", "echo", "marco rossi"]


@pytest.mark.asyncio
async def test_the_assistants_name_is_always_a_hint(db_session):
    # Said by an Italian, "Echo" comes out as "ecco" unless the model expects the name
    from tests.conftest import TEST_USER_ID

    context = await build_stt_context(db_session, TEST_USER_ID)

    assert context.prompt == "Ehi Echo, ricordamelo."
    assert context.keyterms == ["Echo"]
