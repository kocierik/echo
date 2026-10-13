"""Integration tests for audited transcript correction."""

import json
import uuid
from datetime import datetime, timezone
from unittest.mock import AsyncMock

import pytest
from httpx import AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.main import app
from app.models import Conversation, Segment, Transcription, TranscriptionEdit
from app.services.transcription_editor import edit_transcription
from tests.conftest import TEST_USER_ID


class FakeRedis:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str]] = []
        self.set_calls: list[tuple[str, str]] = []
        self.fail_set = False
        self.fail_lpush = False

    async def lpush(self, queue: str, payload: str) -> None:
        if self.fail_lpush:
            raise RuntimeError("redis unavailable")
        self.calls.append((queue, payload))

    async def set(self, key: str, value: str) -> None:
        if self.fail_set:
            raise RuntimeError("redis unavailable")
        self.set_calls.append((key, value))


@pytest.fixture
def fake_redis():
    had_redis = hasattr(app.state, "redis")
    original_redis = getattr(app.state, "redis", None)
    redis = FakeRedis()
    app.state.redis = redis
    try:
        yield redis
    finally:
        if had_redis:
            app.state.redis = original_redis
        else:
            del app.state.redis


async def _seed_transcription(
    db: AsyncSession,
    *,
    user_id: uuid.UUID = TEST_USER_ID,
    text: str = "Original transcript",
    segment_speaker: str = "self",
    transcription_speaker: str | None = "self",
    with_transcription: bool = True,
    with_conversation: bool = True,
) -> tuple[Segment, Transcription | None, Conversation | None]:
    now = datetime.now(timezone.utc)
    conversation = None
    if with_conversation:
        conversation = Conversation(
            user_id=user_id,
            started_at=now,
            analysis_status="completed",
        )
        db.add(conversation)
        await db.flush()

    segment = Segment(
        user_id=user_id,
        received_at=now,
        recorded_at=now,
        duration_ms=1000,
        audio_path="/tmp/correction.adpcm",
        audio_size_bytes=8000,
        speaker=segment_speaker,
        transcription_status="completed",
        conversation_id=conversation.id if conversation else None,
    )
    db.add(segment)
    await db.flush()

    transcription = None
    if with_transcription:
        transcription = Transcription(
            segment_id=segment.id,
            text=text,
            speaker_label=transcription_speaker,
            language="it",
            stt_provider="test",
            stt_model="test",
        )
        db.add(transcription)

    await db.commit()
    return segment, transcription, conversation


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("request_text", "request_speaker", "expected_text", "expected_speaker"),
    [
        ("Corrected transcript", "self", "Corrected transcript", "self"),
        ("Original transcript", "other", "Original transcript", "other"),
        ("Both changed", "unknown", "Both changed", "unknown"),
        ("  Trimmed transcript  ", "self", "Trimmed transcript", "self"),
    ],
)
async def test_changed_correction_is_audited_synchronized_and_queued(
    client: AsyncClient,
    auth_headers,
    db_session: AsyncSession,
    fake_redis: FakeRedis,
    request_text: str,
    request_speaker: str,
    expected_text: str,
    expected_speaker: str,
) -> None:
    segment, transcription, conversation = await _seed_transcription(db_session)
    assert transcription is not None
    assert conversation is not None

    response = await client.patch(
        f"/api/segments/{segment.id}/transcription",
        headers=auth_headers,
        json={"text": request_text, "speaker": request_speaker},
    )

    assert response.status_code == 202
    data = response.json()
    assert data == {
        "segment_id": str(segment.id),
        "transcription_id": str(transcription.id),
        "text": expected_text,
        "speaker_label": expected_speaker,
        "updated_at": data["updated_at"],
        "reanalysis_status": "queued",
    }
    assert datetime.fromisoformat(data["updated_at"]).tzinfo is not None

    await db_session.refresh(segment)
    await db_session.refresh(transcription)
    await db_session.refresh(conversation)
    assert segment.speaker == expected_speaker
    assert transcription.text == expected_text
    assert transcription.speaker_label == expected_speaker
    assert conversation.analysis_status == "reprocessing"

    edits = (
        await db_session.execute(
            select(TranscriptionEdit).where(
                TranscriptionEdit.transcription_id == transcription.id
            )
        )
    ).scalars().all()
    assert len(edits) == 1
    assert edits[0].user_id == TEST_USER_ID
    assert edits[0].old_text == "Original transcript"
    assert edits[0].new_text == expected_text
    assert edits[0].old_speaker_label == "self"
    assert edits[0].new_speaker_label == expected_speaker

    assert len(fake_redis.calls) == 1
    queue, payload = fake_redis.calls[0]
    assert queue == "queue:reanalysis"
    assert json.loads(payload) == {
        "conversation_id": str(conversation.id),
        "requested_at": data["updated_at"],
    }
    assert fake_redis.set_calls == [
        (f"reanalysis:latest:{conversation.id}", data["updated_at"])
    ]


@pytest.mark.asyncio
async def test_empty_text_is_rejected(
    client: AsyncClient, auth_headers, db_session: AsyncSession, fake_redis: FakeRedis
) -> None:
    segment, _, _ = await _seed_transcription(db_session)

    response = await client.patch(
        f"/api/segments/{segment.id}/transcription",
        headers=auth_headers,
        json={"text": "   ", "speaker": "self"},
    )

    assert response.status_code == 422
    assert fake_redis.calls == []


@pytest.mark.asyncio
async def test_invalid_speaker_is_rejected(
    client: AsyncClient, auth_headers, db_session: AsyncSession, fake_redis: FakeRedis
) -> None:
    segment, _, _ = await _seed_transcription(db_session)

    response = await client.patch(
        f"/api/segments/{segment.id}/transcription",
        headers=auth_headers,
        json={"text": "Corrected", "speaker": "speaker-1"},
    )

    assert response.status_code == 422
    assert fake_redis.calls == []


@pytest.mark.asyncio
async def test_foreign_segment_is_not_disclosed(
    client: AsyncClient, auth_headers, db_session: AsyncSession, fake_redis: FakeRedis
) -> None:
    segment, _, _ = await _seed_transcription(db_session, user_id=uuid.uuid4())

    response = await client.patch(
        f"/api/segments/{segment.id}/transcription",
        headers=auth_headers,
        json={"text": "Corrected", "speaker": "self"},
    )

    assert response.status_code == 404
    assert fake_redis.calls == []


@pytest.mark.asyncio
async def test_missing_transcription_is_a_conflict(
    client: AsyncClient, auth_headers, db_session: AsyncSession, fake_redis: FakeRedis
) -> None:
    segment, _, _ = await _seed_transcription(db_session, with_transcription=False)

    response = await client.patch(
        f"/api/segments/{segment.id}/transcription",
        headers=auth_headers,
        json={"text": "Corrected", "speaker": "self"},
    )

    assert response.status_code == 409
    assert fake_redis.calls == []


@pytest.mark.asyncio
async def test_missing_conversation_is_a_conflict(
    client: AsyncClient, auth_headers, db_session: AsyncSession, fake_redis: FakeRedis
) -> None:
    segment, _, _ = await _seed_transcription(db_session, with_conversation=False)

    response = await client.patch(
        f"/api/segments/{segment.id}/transcription",
        headers=auth_headers,
        json={"text": "Corrected", "speaker": "self"},
    )

    assert response.status_code == 409
    assert fake_redis.calls == []


@pytest.mark.asyncio
async def test_unchanged_correction_does_not_mutate_commit_or_queue(
    client: AsyncClient, auth_headers, db_session: AsyncSession, fake_redis: FakeRedis
) -> None:
    segment, transcription, conversation = await _seed_transcription(
        db_session,
        transcription_speaker=None,
    )
    assert transcription is not None
    assert conversation is not None

    response = await client.patch(
        f"/api/segments/{segment.id}/transcription",
        headers=auth_headers,
        json={"text": "Original transcript", "speaker": "self"},
    )

    assert response.status_code == 200
    assert response.json()["reanalysis_status"] == "unchanged"
    await db_session.refresh(conversation)
    assert conversation.analysis_status == "completed"
    assert (
        await db_session.scalar(
            select(func.count(TranscriptionEdit.id)).where(
                TranscriptionEdit.transcription_id == transcription.id
            )
        )
        == 0
    )
    assert fake_redis.calls == []


@pytest.mark.asyncio
async def test_service_unchanged_does_not_commit(db_session: AsyncSession) -> None:
    segment, _, _ = await _seed_transcription(
        db_session,
        transcription_speaker=None,
    )
    commit = AsyncMock(wraps=db_session.commit)
    db_session.commit = commit

    result = await edit_transcription(
        db_session,
        user_id=TEST_USER_ID,
        segment_id=segment.id,
        text="Original transcript",
        speaker="self",
    )

    assert result.changed is False
    commit.assert_not_awaited()


@pytest.mark.asyncio
async def test_mismatched_segment_and_transcription_speakers_are_synchronized(
    client: AsyncClient, auth_headers, db_session: AsyncSession, fake_redis: FakeRedis
) -> None:
    segment, transcription, _ = await _seed_transcription(
        db_session,
        segment_speaker="other",
        transcription_speaker="self",
    )
    assert transcription is not None

    response = await client.patch(
        f"/api/segments/{segment.id}/transcription",
        headers=auth_headers,
        json={"text": "Original transcript", "speaker": "self"},
    )

    assert response.status_code == 202
    await db_session.refresh(segment)
    assert segment.speaker == "self"
    assert response.json()["reanalysis_status"] == "queued"


@pytest.mark.asyncio
@pytest.mark.parametrize("failed_operation", ["set", "lpush"])
async def test_queue_failure_keeps_committed_correction(
    client: AsyncClient,
    auth_headers,
    db_session: AsyncSession,
    fake_redis: FakeRedis,
    failed_operation: str,
) -> None:
    segment, transcription, _ = await _seed_transcription(db_session)
    assert transcription is not None
    if failed_operation == "set":
        fake_redis.fail_set = True
    else:
        fake_redis.fail_lpush = True

    response = await client.patch(
        f"/api/segments/{segment.id}/transcription",
        headers=auth_headers,
        json={"text": "Committed correction", "speaker": "other"},
    )

    assert response.status_code == 202
    assert response.json()["reanalysis_status"] == "queue_failed"
    await db_session.refresh(segment)
    await db_session.refresh(transcription)
    assert segment.speaker == "other"
    assert transcription.text == "Committed correction"
    assert transcription.speaker_label == "other"
    assert (
        await db_session.scalar(
            select(func.count(TranscriptionEdit.id)).where(
                TranscriptionEdit.transcription_id == transcription.id
            )
        )
        == 1
    )
