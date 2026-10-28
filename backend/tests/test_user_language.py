"""The language you speak: one per account, for the wearable's transcription and dictation."""

import asyncio
import uuid
from types import SimpleNamespace

import pytest

from app.core.config import settings
from app.services.language import account_language
from app.services.passwords import create_user
from app.services.transcription_enhancer import STTContext
from app.workers import stt as stt_worker
from tests.test_voice_requests import _SttLoopRedis

PASSWORD = "correct horse battery"


@pytest.fixture(autouse=True)
def _open():
    original = settings.registration_open
    settings.registration_open = True
    yield
    settings.registration_open = original


def _register(email, **extra):
    return {
        "email": email, "password": PASSWORD, "device_name": "Pixel 8", "platform": "android",
        **extra,
    }


async def test_register_keeps_the_phones_language(client):
    english = await client.post("/api/auth/register", json=_register("en@x.io", language="en"))
    german = await client.post("/api/auth/register", json=_register("de@x.io", language="de"))
    unsaid = await client.post("/api/auth/register", json=_register("no@x.io"))

    async def language(response):
        key = {"X-API-Key": response.json()["api_key"]}
        return (await client.get("/api/auth/me", headers=key)).json()["language"]

    assert await language(english) == "en"
    # A language Echo does not transcribe yet: the app's own, English
    assert await language(german) == "en"
    assert await language(unsaid) == settings.stt_language


async def test_me_reads_and_changes_the_language(client):
    key = {"X-API-Key": (await client.post(
        "/api/auth/register", json=_register("ada@x.io", language="en"))).json()["api_key"]}

    me = await client.get("/api/auth/me", headers=key)
    assert me.json() == {
        "email": "ada@x.io", "language": "en", "name": None, "instructions": None,
        "other_languages": [],
    }

    changed = await client.patch("/api/auth/me", headers=key, json={"language": "it"})
    assert changed.status_code == 200 and changed.json()["language"] == "it"
    assert (await client.get("/api/auth/me", headers=key)).json()["language"] == "it"


async def test_me_reads_and_changes_the_name(client):
    key = {"X-API-Key": (await client.post(
        "/api/auth/register", json=_register("erik@x.io", language="it"))).json()["api_key"]}

    named = await client.patch("/api/auth/me", headers=key, json={"name": "  Erik "})
    assert named.status_code == 200 and named.json()["name"] == "Erik"
    # Changing the language keeps the name
    await client.patch("/api/auth/me", headers=key, json={"language": "en"})
    me = (await client.get("/api/auth/me", headers=key)).json()
    assert me == {
        "email": "erik@x.io", "language": "en", "name": "Erik", "instructions": None,
        "other_languages": [],
    }

    cleared = await client.patch("/api/auth/me", headers=key, json={"name": "   "})
    assert cleared.json()["name"] is None
    too_long = await client.patch("/api/auth/me", headers=key, json={"name": "x" * 101})
    assert too_long.status_code == 422


async def test_an_unsupported_language_is_refused(client):
    key = {"X-API-Key": (await client.post(
        "/api/auth/register", json=_register("bo@x.io"))).json()["api_key"]}

    response = await client.patch("/api/auth/me", headers=key, json={"language": "fr"})

    assert response.status_code == 422


async def test_a_key_without_an_account_reads_the_default(client, auth_headers):
    # make create-key keys belong to no account row yet
    me = await client.get("/api/auth/me", headers=auth_headers)

    assert me.status_code == 200
    assert me.json() == {
        "email": None, "language": settings.stt_language, "name": None, "instructions": None,
        "other_languages": [],
    }
    refused = await client.patch("/api/auth/me", headers=auth_headers, json={"language": "en"})
    assert refused.status_code == 409


async def test_account_language_per_user(db_session):
    italian = await create_user(db_session, "it@x.io", PASSWORD)
    english = await create_user(db_session, "en@x.io", PASSWORD)
    english.language = "en"
    await db_session.commit()

    assert await account_language(db_session, italian.id) == settings.stt_language
    assert await account_language(db_session, english.id) == "en"
    assert await account_language(db_session, uuid.uuid4()) == settings.stt_language


async def test_stt_uses_the_owners_language(monkeypatch):
    segment_id = uuid.uuid4()
    owner = uuid.uuid4()
    segment = SimpleNamespace(
        id=segment_id, user_id=owner, audio_energy=10, speaker=None,
        transcription_status="processing",
    )
    asked: list[str] = []

    class _Db:
        def add(self, obj):
            pass

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
        asked.append(kwargs["language"])
        return SimpleNamespace(text="hello there", language=kwargs["language"], confidence=0.9)

    async def classify(_db, _user_id, _energy):
        return "self"

    async def language_of(_db, user_id):
        return "en" if user_id == owner else "it"

    monkeypatch.setattr(
        stt_worker,
        "get_stt_service",
        lambda: SimpleNamespace(transcribe=None, provider="openai", model="gpt-4o-transcribe"),
    )
    monkeypatch.setattr(stt_worker, "async_session", lambda: _Factory())
    monkeypatch.setattr(stt_worker, "_claim_stt_audio", claim)
    monkeypatch.setattr(stt_worker, "adpcm_to_wav", lambda data: data)
    monkeypatch.setattr(stt_worker, "build_stt_context", context)
    monkeypatch.setattr(stt_worker, "retry_with_backoff", retry)
    monkeypatch.setattr(stt_worker, "classify_segment", classify)
    monkeypatch.setattr(stt_worker, "account_language", language_of)

    shutdown = asyncio.Event()
    await asyncio.wait_for(
        stt_worker.process_stt(_SttLoopRedis(segment_id, shutdown), shutdown), timeout=2
    )

    assert asked == ["en"]
