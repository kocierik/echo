"""Tests for side-effect-free conversation reanalysis and its queue worker."""

import asyncio
import json
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

import pytest
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Chunk, Conversation, Entity, EntityMention, Segment, Transcription
from app.services.conversation_reanalysis import reanalyse_conversation
from app.services.llm_base import LLMResponse
from app.workers import reanalysis as reanalysis_worker
from tests.conftest import TEST_USER_ID


@pytest.fixture(autouse=True)
def direct_reanalysis_retries(monkeypatch):
    import app.services.analysis_pipeline as pipeline_module
    import app.services.conversation_reanalysis as reanalysis_module
    from app.services import conversation_close

    async def direct_retry(coro_func, *args, **kwargs):
        kwargs.pop("operation_name", None)
        return await coro_func(*args, **kwargs)

    monkeypatch.setattr(reanalysis_module, "retry_with_backoff", direct_retry)
    # The entities are saved and the summary written by the shared code
    monkeypatch.setattr(pipeline_module, "retry_with_backoff", direct_retry)
    monkeypatch.setattr(conversation_close, "retry_with_backoff", direct_retry)


class RecordingLLM:
    def __init__(self) -> None:
        self.extracted_texts: list[str] = []
        self.summary_texts: list[str] = []
        self.extra_entities: list[dict] = []

    async def complete(self, messages, temperature=0.3):
        return LLMResponse(content="", model="test")

    async def complete_json(self, messages, temperature=0.1):
        system_text = next(message.content for message in messages if message.role == "system")
        user_text = next(message.content for message in messages if message.role == "user")
        if system_text.startswith("Sei un sistema di estrazione"):
            supplied_text = user_text.split("\n\n", 1)[1]
            self.extracted_texts.append(supplied_text)
            return {
                "entities": [
                    {
                        "type": "note",
                        "name": f"Fresh {len(self.extracted_texts)}",
                        "content": "Said late",
                        "metadata": {},
                        "line": 2,
                    },
                    *self.extra_entities,
                ]
            }
        if "You organize the user's conversations." in system_text:
            self.summary_texts.append(user_text.split("\n\n", 1)[1])
            return {"title": "Fresh title", "summary": "Fresh summary", "topics": ["Atlas"]}
        return {"facts": []}  # about the user, about saved people: nothing here


class RecordingEmbeddings:
    def __init__(self, fail: bool = False) -> None:
        self.batches: list[list[str]] = []
        self.fail = fail

    async def embed_batch(self, texts):
        self.batches.append(list(texts))
        if self.fail:
            raise RuntimeError("embedding failure")
        return [[float(index)] * 1536 for index, _ in enumerate(texts, start=1)]


async def _seed_reanalysis_data(db: AsyncSession, *, blank_text: bool = False):
    now = datetime.now(timezone.utc)
    conversation = Conversation(
        user_id=TEST_USER_ID,
        title="Old title",
        summary="Old summary",
        started_at=now,
        analysis_status="reprocessing",
    )
    other_conversation = Conversation(
        user_id=TEST_USER_ID,
        started_at=now,
        analysis_status="completed",
    )
    db.add_all([conversation, other_conversation])
    await db.flush()

    transcriptions = []
    transcription_data = (
        (2, "Late words seven eight nine ten eleven twelve."),
        (1, "Early one two three four five six."),
    )
    for offset, text in transcription_data:
        segment = Segment(
            user_id=TEST_USER_ID,
            received_at=now + timedelta(minutes=offset),
            recorded_at=now + timedelta(minutes=offset),
            duration_ms=1000,
            audio_path=f"/tmp/{offset}.adpcm",
            audio_size_bytes=100,
            transcription_status="completed",
            conversation_id=conversation.id,
        )
        db.add(segment)
        await db.flush()
        transcription = Transcription(
            segment_id=segment.id,
            text="   " if blank_text else text,
            language="it",
            stt_provider="test",
            stt_model="test",
        )
        db.add(transcription)
        await db.flush()
        transcriptions.append(transcription)

    old_chunk = Chunk(
        conversation_id=conversation.id,
        text="stale chunk",
        token_count=2,
        chunk_index=0,
        embedding=[0.0] * 1536,
    )
    target_entity = Entity(
        user_id=TEST_USER_ID,
        entity_type="note",
        name="Stale target",
        metadata_={},
        conversation_id=conversation.id,
        source_transcription_id=transcriptions[0].id,
    )
    null_entity = Entity(
        user_id=TEST_USER_ID,
        entity_type="person",
        name="Global person",
        metadata_={},
        conversation_id=None,
    )
    other_entity = Entity(
        user_id=TEST_USER_ID,
        entity_type="note",
        name="Other conversation",
        metadata_={},
        conversation_id=other_conversation.id,
    )
    db.add_all([old_chunk, target_entity, null_entity, other_entity])
    await db.commit()
    return conversation, target_entity, null_entity, other_entity


@pytest.mark.asyncio
async def test_reanalysis_replaces_only_target_derivatives_and_is_idempotent(
    db_session: AsyncSession, monkeypatch
) -> None:
    conversation, stale_entity, null_entity, other_entity = await _seed_reanalysis_data(
        db_session
    )
    llm = RecordingLLM()
    embeddings = RecordingEmbeddings()

    first_result = await reanalyse_conversation(
        db_session, conversation.id, llm, embeddings
    )

    assert first_result.found is True
    # The whole conversation in one reading, its lines numbered
    assert llm.extracted_texts == [
        "[1] Early one two three four five six.\n"
        "[2] Late words seven eight nine ten eleven twelve."
    ]
    assert llm.summary_texts == [
        "Early one two three four five six. Late words seven eight nine ten eleven twelve."
    ]
    await db_session.refresh(conversation)
    assert conversation.title == "Fresh title"
    assert conversation.summary == "Fresh summary"
    # As any closed conversation: its topics too, which a reanalysis used to skip
    assert conversation.topics == ["atlas"]
    assert conversation.analysis_status == "completed"

    target_entities = (
        await db_session.execute(
            select(Entity)
            .where(Entity.conversation_id == conversation.id)
            .order_by(Entity.name)
        )
    ).scalars().all()
    assert len(target_entities) == 1
    assert stale_entity.id not in {entity.id for entity in target_entities}
    assert all(entity.embedding is not None for entity in target_entities)
    # Its source is the line the model named: the second, said late
    late = (
        await db_session.execute(
            select(Transcription.id).where(Transcription.text.startswith("Late"))
        )
    ).scalar_one()
    assert target_entities[0].source_transcription_id == late
    assert await db_session.get(Entity, null_entity.id) is not None
    assert await db_session.get(Entity, other_entity.id) is not None

    chunks = (
        await db_session.execute(
            select(Chunk)
            .where(Chunk.conversation_id == conversation.id)
            .order_by(Chunk.chunk_index)
        )
    ).scalars().all()
    assert len(chunks) == 1
    assert chunks[0].text == llm.summary_texts[0]
    assert chunks[0].embedding is not None

    await reanalyse_conversation(db_session, conversation.id, llm, embeddings)

    assert await db_session.scalar(
        select(func.count(Entity.id)).where(Entity.conversation_id == conversation.id)
    ) == 1
    assert await db_session.scalar(
        select(func.count(Chunk.id)).where(Chunk.conversation_id == conversation.id)
    ) == 1


@pytest.mark.asyncio
async def test_a_saved_person_named_only_here_survives_and_is_mentioned(
    db_session: AsyncSession,
) -> None:
    """People are the user's own: analysing a conversation again deleted one it alone
    named, with their facts and their voice."""
    conversation, _, _, _ = await _seed_reanalysis_data(db_session)
    marco = Entity(
        user_id=TEST_USER_ID, entity_type="person", name="Marco", metadata_={},
        conversation_id=conversation.id,
    )
    db_session.add(marco)
    await db_session.commit()
    marco_id, conversation_id = marco.id, conversation.id
    llm = RecordingLLM()
    llm.extra_entities = [
        {"type": "person", "name": "Marco", "content": "Friend", "metadata": {}, "line": 1},
        {"type": "person", "name": "Nobody saved", "content": "", "metadata": {}, "line": 1},
    ]

    await reanalyse_conversation(db_session, conversation_id, llm, RecordingEmbeddings())

    people = (
        await db_session.execute(
            select(Entity.id).where(Entity.user_id == TEST_USER_ID, Entity.name == "Marco")
        )
    ).scalars().all()
    assert people == [marco_id]
    assert await db_session.scalar(
        select(func.count(EntityMention.id)).where(
            EntityMention.entity_id == marco_id,
            EntityMention.conversation_id == conversation_id,
        )
    ) == 1
    assert await db_session.scalar(
        select(func.count(Entity.id)).where(Entity.name == "Nobody saved")
    ) == 0


@pytest.mark.asyncio
async def test_reanalysis_of_conversation_without_text_clears_target_derivatives(
    db_session: AsyncSession,
) -> None:
    conversation, _, null_entity, other_entity = await _seed_reanalysis_data(
        db_session, blank_text=True
    )

    result = await reanalyse_conversation(
        db_session, conversation.id, RecordingLLM(), RecordingEmbeddings()
    )

    await db_session.refresh(conversation)
    assert result.found is True
    assert result.entity_count == 0
    assert result.chunk_count == 0
    assert conversation.title is None
    assert conversation.summary is None
    assert conversation.analysis_status == "completed"
    assert await db_session.scalar(
        select(func.count(Entity.id)).where(Entity.conversation_id == conversation.id)
    ) == 0
    assert await db_session.get(Entity, null_entity.id) is not None
    assert await db_session.get(Entity, other_entity.id) is not None


@pytest.mark.asyncio
async def test_reanalysis_rolls_back_replacement_on_failure(db_session: AsyncSession) -> None:
    conversation, stale_entity, _, _ = await _seed_reanalysis_data(db_session)
    # The rollback expires every loaded object, so keep the ids before it happens
    conversation_id, stale_entity_id = conversation.id, stale_entity.id

    with pytest.raises(RuntimeError, match="embedding failure"):
        await reanalyse_conversation(
            db_session, conversation_id, RecordingLLM(), RecordingEmbeddings(fail=True)
        )

    assert await db_session.get(Entity, stale_entity_id) is not None
    assert await db_session.scalar(
        select(func.count(Chunk.id)).where(Chunk.conversation_id == conversation_id)
    ) == 1
    persisted = await db_session.get(Conversation, conversation_id)
    assert persisted is not None
    assert persisted.analysis_status == "reprocessing"


@pytest.mark.asyncio
async def test_reanalysis_returns_not_found_signal(db_session: AsyncSession) -> None:
    result = await reanalyse_conversation(
        db_session, uuid.uuid4(), RecordingLLM(), RecordingEmbeddings()
    )

    assert result.found is False


_UNCHANGED = object()


class QueueRedis:
    def __init__(
        self,
        *,
        lock_acquired=True,
        marker=None,
        marker_before_compare_delete=_UNCHANGED,
        renewal_results=None,
    ) -> None:
        self.lock_acquired = lock_acquired
        self.latest_marker = marker
        self.marker_before_compare_delete = marker_before_compare_delete
        self.renewal_results = list(renewal_results or [])
        self.lock_value = None
        self.lock_gets = 0
        self.pushes: list[tuple[str, str]] = []
        self.eval_calls: list[tuple[str, int, tuple]] = []

    async def set(self, key, value, *_args, **_kwargs):
        if self.lock_acquired:
            self.lock_value = value.encode()
        return self.lock_acquired

    async def get(self, key):
        if key.startswith("reanalysis:lock:"):
            self.lock_gets += 1
            return self.lock_value
        return self.latest_marker

    async def lpush(self, queue, payload):
        self.pushes.append((queue, payload))

    async def eval(self, script, key_count, *args):
        self.eval_calls.append((script, key_count, args))
        if script == reanalysis_worker._RENEW_LOCK_SCRIPT:
            renewed = self.renewal_results.pop(0) if self.renewal_results else 1
            if not renewed:
                self.lock_value = None
            return renewed
        if script == reanalysis_worker._RELEASE_LOCK_SCRIPT:
            if reanalysis_worker._decode_redis_token(self.lock_value) == args[1]:
                self.lock_value = None
                return 1
            return 0
        if script == reanalysis_worker._DELETE_LATEST_IF_UNCHANGED_SCRIPT:
            if self.marker_before_compare_delete is not _UNCHANGED:
                self.latest_marker = self.marker_before_compare_delete
                self.marker_before_compare_delete = _UNCHANGED
            if self.latest_marker == args[1]:
                self.latest_marker = None
                return 1
            return 0
        return 1


@pytest.mark.asyncio
async def test_reanalysis_worker_dead_letters_malformed_payload() -> None:
    redis = QueueRedis()

    await reanalysis_worker._process_reanalysis_payload(
        redis, b"not-json", RecordingLLM(), RecordingEmbeddings()
    )

    assert redis.pushes[0][0] == "queue:dead-letter"
    assert json.loads(redis.pushes[0][1])["step"] == "reanalysis"


@pytest.mark.asyncio
async def test_reanalysis_worker_requeues_lock_contention_with_bounded_backoff(
    monkeypatch,
) -> None:
    redis = QueueRedis(lock_acquired=False)
    sleep = AsyncMock()
    monkeypatch.setattr(reanalysis_worker.asyncio, "sleep", sleep)
    payload = {
        "conversation_id": str(uuid.uuid4()),
        "requested_at": datetime.now(timezone.utc).isoformat(),
    }

    await reanalysis_worker._process_reanalysis_payload(
        redis, json.dumps(payload), RecordingLLM(), RecordingEmbeddings()
    )

    sleep.assert_awaited_once_with(2)
    queue, encoded = redis.pushes[0]
    assert queue == "queue:reanalysis"
    assert json.loads(encoded)["attempts"] == 1

    redis.pushes.clear()
    payload["attempts"] = 4
    await reanalysis_worker._process_reanalysis_payload(
        redis, json.dumps(payload), RecordingLLM(), RecordingEmbeddings()
    )
    assert redis.pushes[0][0] == "queue:dead-letter"


@pytest.mark.asyncio
async def test_reanalysis_worker_repeats_for_newer_marker_and_releases_lock(
    monkeypatch,
) -> None:
    requested_at = datetime.now(timezone.utc)
    newer_at = requested_at + timedelta(seconds=1)
    redis = QueueRedis(marker=newer_at.isoformat())
    reanalyse = AsyncMock(return_value=type("Result", (), {"found": True})())
    monkeypatch.setattr(reanalysis_worker, "reanalyse_conversation", reanalyse)

    @asynccontextmanager
    async def fake_session():
        yield object()

    monkeypatch.setattr(reanalysis_worker, "async_session", fake_session)
    payload = json.dumps(
        {
            "conversation_id": str(uuid.uuid4()),
            "requested_at": requested_at.isoformat(),
        }
    )

    await reanalysis_worker._process_reanalysis_payload(
        redis, payload, RecordingLLM(), RecordingEmbeddings()
    )

    assert reanalyse.await_count == 2
    assert redis.lock_gets == 4
    assert redis.latest_marker is None
    assert any(
        script == reanalysis_worker._DELETE_LATEST_IF_UNCHANGED_SCRIPT
        for script, _, _ in redis.eval_calls
    )


@pytest.mark.asyncio
async def test_reanalysis_worker_accepts_missing_marker_after_success(
    monkeypatch,
) -> None:
    redis = QueueRedis()
    reanalyse = AsyncMock(return_value=type("Result", (), {"found": True})())
    monkeypatch.setattr(reanalysis_worker, "reanalyse_conversation", reanalyse)

    @asynccontextmanager
    async def fake_session():
        yield object()

    monkeypatch.setattr(reanalysis_worker, "async_session", fake_session)
    payload = json.dumps(
        {
            "conversation_id": str(uuid.uuid4()),
            "requested_at": datetime.now(timezone.utc).isoformat(),
        }
    )

    await reanalysis_worker._process_reanalysis_payload(
        redis, payload, RecordingLLM(), RecordingEmbeddings()
    )

    reanalyse.assert_awaited_once()
    assert not any(
        script == reanalysis_worker._DELETE_LATEST_IF_UNCHANGED_SCRIPT
        for script, _, _ in redis.eval_calls
    )


@pytest.mark.asyncio
async def test_reanalysis_worker_does_not_delete_marker_replaced_after_get(
    monkeypatch,
) -> None:
    requested_at = datetime.now(timezone.utc)
    replacement = (requested_at + timedelta(seconds=1)).isoformat()
    redis = QueueRedis(
        marker=requested_at.isoformat(),
        marker_before_compare_delete=replacement,
    )
    monkeypatch.setattr(
        reanalysis_worker,
        "reanalyse_conversation",
        AsyncMock(return_value=type("Result", (), {"found": True})()),
    )

    @asynccontextmanager
    async def fake_session():
        yield object()

    monkeypatch.setattr(reanalysis_worker, "async_session", fake_session)
    payload = json.dumps(
        {
            "conversation_id": str(uuid.uuid4()),
            "requested_at": requested_at.isoformat(),
        }
    )

    await reanalysis_worker._process_reanalysis_payload(
        redis, payload, RecordingLLM(), RecordingEmbeddings()
    )

    assert redis.latest_marker == replacement


@pytest.mark.asyncio
async def test_reanalysis_worker_requeues_when_lock_renewal_is_lost(
    monkeypatch,
) -> None:
    real_sleep = asyncio.sleep

    async def yield_once(_delay):
        await real_sleep(0)

    async def reanalyse_once(*_args, **_kwargs):
        await real_sleep(0)
        await real_sleep(0)
        return type("Result", (), {"found": True})()

    redis = QueueRedis(renewal_results=[0])
    reanalyse = AsyncMock(side_effect=reanalyse_once)
    monkeypatch.setattr(reanalysis_worker.asyncio, "sleep", yield_once)
    monkeypatch.setattr(reanalysis_worker, "reanalyse_conversation", reanalyse)

    @asynccontextmanager
    async def fake_session():
        yield object()

    monkeypatch.setattr(reanalysis_worker, "async_session", fake_session)
    payload_data = {
        "conversation_id": str(uuid.uuid4()),
        "requested_at": datetime.now(timezone.utc).isoformat(),
    }

    await reanalysis_worker._process_reanalysis_payload(
        redis,
        json.dumps(payload_data),
        RecordingLLM(),
        RecordingEmbeddings(),
    )

    reanalyse.assert_awaited_once()
    assert len(redis.pushes) == 1
    queue, encoded = redis.pushes[0]
    assert queue == "queue:reanalysis"
    requeued = json.loads(encoded)
    assert requeued["requested_at"] == payload_data["requested_at"]
    assert requeued["attempts"] == 1
    assert all(queue != "queue:dead-letter" for queue, _ in redis.pushes)


@pytest.mark.asyncio
async def test_reanalysis_worker_cancellation_requeues_and_releases_lock(
    monkeypatch,
) -> None:
    redis = QueueRedis()
    monkeypatch.setattr(
        reanalysis_worker,
        "reanalyse_conversation",
        AsyncMock(side_effect=asyncio.CancelledError),
    )

    @asynccontextmanager
    async def fake_session():
        yield object()

    monkeypatch.setattr(reanalysis_worker, "async_session", fake_session)
    payload_data = {
        "conversation_id": str(uuid.uuid4()),
        "requested_at": datetime.now(timezone.utc).isoformat(),
    }

    with pytest.raises(asyncio.CancelledError):
        await reanalysis_worker._process_reanalysis_payload(
            redis,
            json.dumps(payload_data),
            RecordingLLM(),
            RecordingEmbeddings(),
        )

    assert len(redis.pushes) == 1
    assert redis.pushes[0][0] == "queue:reanalysis"
    requeued = json.loads(redis.pushes[0][1])
    assert requeued["conversation_id"] == payload_data["conversation_id"]
    assert requeued["requested_at"] == payload_data["requested_at"]
    assert any("del" in script.lower() for script, _, _ in redis.eval_calls)
