"""Every model call is counted for the user it serves: the key's user during a request, the
row's user in each worker job."""

import asyncio
import uuid
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from app.services import analysis_pipeline as pipeline_module
from app.services import photos as photo_service
from app.services import weekly_digest as weekly
from app.services.conversation_reanalysis import reanalyse_conversation
from app.services.transcription_enhancer import STTContext
from app.services.usage import usage_owner
from app.workers import stt as stt_worker
from app.workers import summaries
from app.workers.digest import generate_digest_for_date
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation
from tests.mocks import MockEmbeddingService, MockLLMService
from tests.test_conversation_summaries import _FakeLLM, _FakeSession, _patch_direct_retry
from tests.test_photos import Embeddings, VisionLLM, _request, _upload
from tests.test_voice_requests import _SttLoopRedis
from tests.test_weekly_digest import WEEK, WeekLLM, _week_with_marco


def _spy(obj, seen: list):
    """Wraps the model methods of `obj` so each call notes who owns the work."""
    for name in ("complete", "complete_json", "complete_with_tools", "embed", "embed_batch"):
        method = getattr(obj, name, None)
        if method is None:
            continue

        def wrap(method=method):
            async def spied(*args, **kwargs):
                seen.append(usage_owner.get())
                return await method(*args, **kwargs)

            return spied

        setattr(obj, name, wrap())
    return obj


async def test_a_request_runs_as_its_key_owner(client, auth_headers):
    seen: list = []
    embeddings = _spy(MockEmbeddingService(), seen)
    with (
        patch("app.routers.query.get_embedding_service", lambda: embeddings),
        patch("app.routers.query.get_llm_query_service", MockLLMService),
    ):
        await client.post("/api/query", headers=auth_headers, json={"question": "Marco?"})

    assert seen and set(seen) == {TEST_USER_ID}


async def test_the_stt_job_runs_as_the_segment_owner(monkeypatch):
    owner = uuid.uuid4()
    segment = SimpleNamespace(
        id=uuid.uuid4(), user_id=owner, audio_energy=10, speaker=None,
        transcription_status="processing",
    )
    seen: list = []

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

    async def claim(_db, _redis, _segment_id):
        return segment, b""

    async def context(_db, _user_id):
        return STTContext(prompt="", keyterms=[])

    async def retry(func, *args, **kwargs):
        seen.append(usage_owner.get())
        return SimpleNamespace(text="ciao a tutti", language="it", confidence=0.9)

    async def classify(_db, _user_id, _energy):
        return "self"

    async def language(_db, _user_id):
        return "it"

    monkeypatch.setattr(
        stt_worker, "get_stt_service",
        lambda: SimpleNamespace(transcribe=None, provider="openai", model="m"),
    )
    monkeypatch.setattr(stt_worker, "async_session", lambda: _Factory())
    monkeypatch.setattr(stt_worker, "_claim_stt_audio", claim)
    monkeypatch.setattr(stt_worker, "adpcm_to_wav", lambda data: data)
    monkeypatch.setattr(stt_worker, "build_stt_context", context)
    monkeypatch.setattr(stt_worker, "retry_with_backoff", retry)
    monkeypatch.setattr(stt_worker, "classify_segment", classify)
    monkeypatch.setattr(stt_worker, "account_language", language)

    shutdown = asyncio.Event()
    await asyncio.wait_for(
        stt_worker.process_stt(_SttLoopRedis(segment.id, shutdown), shutdown), timeout=2
    )

    assert seen == [owner]


async def test_analysis_runs_as_the_segment_owner(monkeypatch):
    owner = uuid.uuid4()
    seen: list = []

    class _StopError(Exception):
        pass

    async def assign(_db, _segment):
        seen.append(usage_owner.get())
        raise _StopError

    monkeypatch.setattr(pipeline_module, "assign_to_conversation", assign)
    pipeline = pipeline_module.AnalysisPipeline(MockLLMService(), MockEmbeddingService())
    segment = SimpleNamespace(
        id=uuid.uuid4(), user_id=owner,
        transcription=SimpleNamespace(id=uuid.uuid4(), text="ciao"),
        recorded_at=datetime.now(timezone.utc),
    )

    with pytest.raises(_StopError):
        await pipeline.analyze_segment(SimpleNamespace(), segment)

    assert seen == [owner]


async def test_summaries_run_as_the_conversation_owner(monkeypatch):
    _patch_direct_retry(monkeypatch)
    owner = uuid.uuid4()
    conversation = SimpleNamespace(
        id=uuid.uuid4(), user_id=owner, title=None, summary=None, emoji=None
    )
    session = _FakeSession(
        [conversation],
        {
            conversation.id: [
                "[Tu] Domani pranzo con Ada.",
                "Parliamo del progetto Atlas e dei tempi di consegna.",
            ]
        },
    )
    seen: list = []
    llm = _spy(_FakeLLM(), seen)

    await summaries.summarize_closed_conversations(
        now=datetime.now(timezone.utc), session_factory=lambda: session, llm_service=llm
    )

    assert seen == [owner]


async def test_the_weekly_summary_runs_as_its_user(db_session):
    await _week_with_marco(db_session)
    seen: list = []

    await weekly.generate_weekly_digest(db_session, TEST_USER_ID, WEEK, _spy(WeekLLM(), seen))

    assert seen == [TEST_USER_ID]


async def test_the_daily_digest_runs_as_its_user(db_session):
    user = uuid.uuid4()
    usage_owner.set(None)

    await generate_digest_for_date(user, datetime(2026, 10, 13).date(), db_session)

    assert usage_owner.get() == user


async def test_photo_analysis_runs_as_the_photo_owner(client, auth_headers, db_session):
    photo = await _request(client, auth_headers, question="Che pianta è questa?")
    await _upload(client, auth_headers, photo["id"])
    seen: list = []
    usage_owner.set(None)

    await photo_service.analyse_photo(
        db_session, uuid.UUID(photo["id"]), _spy(VisionLLM(), seen), _spy(Embeddings(), seen)
    )

    assert seen and set(seen) == {TEST_USER_ID}


async def test_reanalysis_runs_as_the_conversation_owner(db_session):
    conversation, _ = await make_conversation(
        db_session, started_at=datetime(2026, 10, 13, 9, tzinfo=timezone.utc)
    )
    usage_owner.set(None)

    await reanalyse_conversation(
        db_session, conversation.id, MockLLMService(), MockEmbeddingService()
    )

    assert usage_owner.get() == TEST_USER_ID
