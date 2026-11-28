"""Recognising the language spoken: with other languages heard, each provider detects
among the account's languages and reports the one it heard; without, nothing changes."""

import asyncio
import uuid
from types import SimpleNamespace

import httpx
import pytest

from app.core.config import settings
from app.services import stt_openai
from app.services.stt_deepgram import DeepgramSTTService
from app.services.stt_openai import OpenAISTTService
from app.services.transcription_enhancer import STTContext
from app.workers import stt as stt_worker
from tests.test_voice_requests import _SttLoopRedis


def _deepgram(monkeypatch, responses: list[httpx.Response], seen: list[httpx.Request]):
    monkeypatch.setattr(settings, "deepgram_model", "nova-3")

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return responses.pop(0)

    return DeepgramSTTService(transport=httpx.MockTransport(handler))


def _heard(text: str, detected: str | None) -> httpx.Response:
    channel = {"alternatives": [{"transcript": text, "confidence": 0.9}]}
    if detected is not None:
        channel["detected_language"] = detected
    return httpx.Response(200, json={"results": {"channels": [channel]}})


async def test_deepgram_without_other_languages_asks_as_before(monkeypatch):
    seen: list[httpx.Request] = []
    service = _deepgram(monkeypatch, [_heard("Ciao", None)], seen)

    result = await service.transcribe(b"wav", language="it", keyterms=["Marco"])

    params = seen[0].url.params
    assert params["language"] == "it"
    assert params.get_list("detect_language") == []
    assert result.language == "it"


async def test_deepgram_never_picks_among_all_its_languages(monkeypatch):
    """language=multi heard "Prova prova uno due tre" as Croatian: detection stays within
    the account's languages, even for Italian with English."""
    seen: list[httpx.Request] = []
    service = _deepgram(monkeypatch, [_heard("Prova prova 1 2 3", "it")], seen)

    result = await service.transcribe(b"wav", language="it", keyterms=["Marco"], also=["en"])

    params = seen[0].url.params
    assert "language" not in params
    assert params.get_list("detect_language") == ["it", "en"]
    assert params.get_list("keyterm") == ["Marco"]
    assert result.language == "it"


async def test_deepgram_detects_among_languages_it_cannot_mix(monkeypatch):
    seen: list[httpx.Request] = []
    service = _deepgram(monkeypatch, [_heard("Vi ses i morgon", "sv")], seen)

    result = await service.transcribe(b"wav", language="it", keyterms=["Marco"], also=["sv"])

    params = seen[0].url.params
    assert "language" not in params
    assert params.get_list("detect_language") == ["it", "sv"]
    assert (result.text, result.language) == ("Vi ses i morgon", "sv")


@pytest.mark.parametrize("detected", ["ja", None])
async def test_deepgram_detecting_something_else_or_nothing_is_the_main_language(
    monkeypatch, detected
):
    seen: list[httpx.Request] = []
    service = _deepgram(monkeypatch, [_heard("Ciao", detected)], seen)

    result = await service.transcribe(b"wav", language="it", also=["en"])

    assert result.language == "it"


async def test_deepgram_refusing_keyterms_with_detection_is_asked_again_without(monkeypatch):
    seen: list[httpx.Request] = []
    refused = httpx.Response(400, json={"err_msg": "keyterm not supported"})
    service = _deepgram(monkeypatch, [refused, _heard("Hola", "es")], seen)

    result = await service.transcribe(b"wav", language="it", keyterms=["Marco"], also=["es"])

    assert len(seen) == 2
    assert seen[0].url.params.get_list("keyterm") == ["Marco"]
    assert seen[1].url.params.get_list("keyterm") == []
    assert result.language == "es"


def _openai(monkeypatch, model: str, response) -> list[dict]:
    calls: list[dict] = []

    class _Transcriptions:
        async def create(self, **kwargs):
            calls.append(kwargs)
            return response

    class _Client:
        def __init__(self, api_key):
            self.audio = SimpleNamespace(transcriptions=_Transcriptions())

    monkeypatch.setattr(stt_openai, "AsyncOpenAI", _Client)
    monkeypatch.setattr(settings, "stt_model", model)
    return calls


async def test_openai_gpt_transcribe_gets_every_language(monkeypatch):
    calls = _openai(monkeypatch, "gpt-transcribe", SimpleNamespace(text="Hello"))

    result = await OpenAISTTService().transcribe(b"wav", language="it", also=["en", "es"])

    assert calls[0]["extra_body"] == {"languages": ["it", "en", "es"]}
    assert result.language == "it"


async def test_openai_whisper_detects_and_says_what_it_heard(monkeypatch):
    calls = _openai(
        monkeypatch, "whisper-1", SimpleNamespace(text="Hello", language="english")
    )

    result = await OpenAISTTService().transcribe(b"wav", language="it", also=["en"])

    assert "language" not in calls[0]
    assert result.language == "en"


async def test_openai_other_models_get_no_hint_with_other_languages(monkeypatch):
    calls = _openai(monkeypatch, "gpt-4o-transcribe", SimpleNamespace(text="Hello"))

    result = await OpenAISTTService().transcribe(b"wav", language="it", also=["en"])

    assert "language" not in calls[0]
    assert result.language == "it"


async def test_openai_without_other_languages_asks_as_before(monkeypatch):
    calls = _openai(monkeypatch, "gpt-4o-transcribe", SimpleNamespace(text="Ciao"))

    await OpenAISTTService().transcribe(b"wav", language="it")

    assert calls[0]["language"] == "it"


async def test_the_worker_passes_the_other_languages_and_keeps_what_was_heard(monkeypatch):
    segment_id = uuid.uuid4()
    owner = uuid.uuid4()
    segment = SimpleNamespace(
        id=segment_id, user_id=owner, audio_energy=10, speaker=None,
        transcription_status="processing",
    )
    asked: list[dict] = []
    saved: list = []

    class _Db:
        def add(self, obj):
            saved.append(obj)

        async def commit(self):
            pass

    class _Factory:
        async def __aenter__(self):
            return _Db()

        async def __aexit__(self, *exc):
            return False

    async def claim(_db, _redis, _segment_id, **_):
        return segment, b""

    async def context(_db, _user_id):
        return STTContext(prompt="", keyterms=[])

    async def retry(func, *args, **kwargs):
        asked.append(kwargs)
        return SimpleNamespace(text="see you tomorrow", language="en", confidence=0.9)

    async def classify(_db, _user_id, _energy):
        return "other"

    async def languages_of(_db, user_id):
        return ("it", ["en"])

    monkeypatch.setattr(
        stt_worker,
        "get_stt_service",
        lambda: SimpleNamespace(transcribe=None, provider="deepgram", model="nova-3"),
    )
    monkeypatch.setattr(stt_worker, "async_session", lambda: _Factory())
    monkeypatch.setattr(stt_worker, "_claim_stt_audio", claim)
    monkeypatch.setattr(stt_worker, "segment_to_wav", lambda data: data)
    monkeypatch.setattr(stt_worker, "build_stt_context", context)
    monkeypatch.setattr(stt_worker, "retry_with_backoff", retry)
    monkeypatch.setattr(stt_worker, "classify_segment", classify)
    monkeypatch.setattr(stt_worker, "account_languages", languages_of)

    shutdown = asyncio.Event()
    await asyncio.wait_for(
        stt_worker.process_stt(_SttLoopRedis(segment_id, shutdown), shutdown), timeout=2
    )

    assert (asked[0]["language"], asked[0]["also"]) == ("it", ["en"])
    # Each word with who says it: several voices in a segment become its turns
    assert asked[0]["diarize"] is True
    [transcription] = [obj for obj in saved if type(obj).__name__ == "Transcription"]
    assert transcription.language == "en"
