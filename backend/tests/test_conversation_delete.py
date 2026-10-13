"""Conversation deletion API and storage transaction tests."""

import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.main import app
from app.models import (
    Chunk,
    Conversation,
    Entity,
    Segment,
    Transcription,
    TranscriptionEdit,
)
from app.services.conversation_deleter import (
    ConversationStorage,
    delete_conversation,
    get_conversation_storage,
)
from tests.conftest import TEST_USER_ID


class FailingRenameStorage(ConversationStorage):
    def __init__(self, fail_on_call: int) -> None:
        self.fail_on_call = fail_on_call
        self.rename_calls = 0

    def exists(self, path: Path) -> bool:
        return path.exists()

    def rename(self, source: Path, destination: Path) -> None:
        self.rename_calls += 1
        if self.rename_calls == self.fail_on_call:
            raise OSError("injected stage failure")
        source.rename(destination)

    def unlink(self, path: Path) -> None:
        path.unlink()


class FailingUnlinkStorage(ConversationStorage):
    def exists(self, path: Path) -> bool:
        return path.exists()

    def rename(self, source: Path, destination: Path) -> None:
        source.rename(destination)

    def unlink(self, path: Path) -> None:
        raise OSError("injected cleanup failure")


class CommitFailingSession:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.rollback_calls = 0

    async def execute(self, statement):
        return await self.session.execute(statement)

    async def delete(self, instance) -> None:
        await self.session.delete(instance)

    async def commit(self) -> None:
        raise RuntimeError("injected commit failure")

    async def rollback(self) -> None:
        self.rollback_calls += 1
        await self.session.rollback()


async def _seed_complete_graph(db: AsyncSession, tmp_path: Path) -> dict[str, object]:
    now = datetime.now(timezone.utc)
    target = Conversation(
        user_id=TEST_USER_ID,
        title="Delete me",
        started_at=now,
        analysis_status="completed",
    )
    other = Conversation(
        user_id=TEST_USER_ID,
        title="Keep me",
        started_at=now + timedelta(minutes=1),
        analysis_status="completed",
    )
    db.add_all([target, other])
    await db.flush()

    audio_paths = [tmp_path / "first.adpcm", tmp_path / "second.adpcm"]
    for path in audio_paths:
        path.write_bytes(b"audio")
    other_audio_path = tmp_path / "other.adpcm"
    other_audio_path.write_bytes(b"other")

    target_segments = [
        Segment(
            user_id=TEST_USER_ID,
            received_at=now + timedelta(seconds=index),
            recorded_at=now + timedelta(seconds=index),
            duration_ms=1000,
            audio_path=str(path),
            audio_size_bytes=path.stat().st_size,
            transcription_status="completed",
            conversation_id=target.id,
        )
        for index, path in enumerate(audio_paths)
    ]
    other_segment = Segment(
        user_id=TEST_USER_ID,
        received_at=now,
        recorded_at=now,
        duration_ms=1000,
        audio_path=str(other_audio_path),
        audio_size_bytes=other_audio_path.stat().st_size,
        transcription_status="completed",
        conversation_id=other.id,
    )
    db.add_all([*target_segments, other_segment])
    await db.flush()

    target_transcription = Transcription(
        segment_id=target_segments[0].id,
        text="Target transcript",
        language="it",
        stt_provider="test",
        stt_model="test",
    )
    other_transcription = Transcription(
        segment_id=other_segment.id,
        text="Other transcript",
        language="it",
        stt_provider="test",
        stt_model="test",
    )
    db.add_all([target_transcription, other_transcription])
    await db.flush()

    target_edit = TranscriptionEdit(
        transcription_id=target_transcription.id,
        user_id=TEST_USER_ID,
        old_text="Old target transcript",
        new_text="Target transcript",
    )
    target_chunk = Chunk(
        conversation_id=target.id,
        text="Target chunk",
        token_count=2,
        chunk_index=0,
        embedding=[0.1] * 1536,
    )
    target_entity = Entity(
        user_id=TEST_USER_ID,
        entity_type="note",
        name="Target entity",
        metadata_={},
        embedding=[0.2] * 1536,
        source_transcription_id=target_transcription.id,
        conversation_id=target.id,
    )
    external_entity = Entity(
        user_id=TEST_USER_ID,
        entity_type="note",
        name="External source reference",
        metadata_={},
        source_transcription_id=target_transcription.id,
        conversation_id=None,
    )
    null_entity = Entity(
        user_id=TEST_USER_ID,
        entity_type="person",
        name="Global entity",
        metadata_={},
        source_transcription_id=None,
        conversation_id=None,
    )
    other_entity = Entity(
        user_id=TEST_USER_ID,
        entity_type="note",
        name="Other conversation entity",
        metadata_={},
        source_transcription_id=other_transcription.id,
        conversation_id=other.id,
    )
    db.add_all(
        [
            target_edit,
            target_chunk,
            target_entity,
            external_entity,
            null_entity,
            other_entity,
        ]
    )
    await db.commit()

    return {
        "target_id": target.id,
        "other_id": other.id,
        "target_segment_ids": [segment.id for segment in target_segments],
        "target_transcription_id": target_transcription.id,
        "target_edit_id": target_edit.id,
        "target_chunk_id": target_chunk.id,
        "target_entity_id": target_entity.id,
        "external_entity_id": external_entity.id,
        "null_entity_id": null_entity.id,
        "other_entity_id": other_entity.id,
        "audio_paths": audio_paths,
        "other_audio_path": other_audio_path,
    }


@pytest.mark.asyncio
async def test_delete_conversation_removes_owned_graph_and_audio_only(
    client,
    auth_headers,
    db_session: AsyncSession,
    tmp_path: Path,
) -> None:
    seeded = await _seed_complete_graph(db_session, tmp_path)

    response = await client.delete(
        f"/api/conversations/{seeded['target_id']}",
        headers=auth_headers,
    )

    assert response.status_code == 204
    assert response.content == b""
    assert all(not path.exists() for path in seeded["audio_paths"])
    assert list(tmp_path.glob(".echo-delete-*")) == []
    assert seeded["other_audio_path"].exists()

    db_session.expire_all()
    assert await db_session.get(Conversation, seeded["target_id"]) is None
    for segment_id in seeded["target_segment_ids"]:
        assert await db_session.get(Segment, segment_id) is None
    assert await db_session.get(
        Transcription, seeded["target_transcription_id"]
    ) is None
    assert await db_session.get(TranscriptionEdit, seeded["target_edit_id"]) is None
    assert await db_session.get(Chunk, seeded["target_chunk_id"]) is None
    assert await db_session.get(Entity, seeded["target_entity_id"]) is None

    external = await db_session.get(Entity, seeded["external_entity_id"])
    assert external is not None
    assert external.source_transcription_id is None
    assert await db_session.get(Entity, seeded["null_entity_id"]) is not None
    assert await db_session.get(Entity, seeded["other_entity_id"]) is not None

    detail_response = await client.get(
        f"/api/conversations/{seeded['other_id']}",
        headers=auth_headers,
    )
    assert detail_response.status_code == 200


@pytest.mark.asyncio
async def test_delete_conversation_hides_foreign_and_missing_ids(
    client,
    auth_headers,
    db_session: AsyncSession,
    tmp_path: Path,
) -> None:
    foreign_user_id = uuid.uuid4()
    foreign_audio = tmp_path / "foreign.adpcm"
    foreign_audio.write_bytes(b"foreign")
    conversation = Conversation(
        user_id=foreign_user_id,
        started_at=datetime.now(timezone.utc),
        analysis_status="completed",
    )
    db_session.add(conversation)
    await db_session.flush()
    segment = Segment(
        user_id=foreign_user_id,
        received_at=datetime.now(timezone.utc),
        recorded_at=datetime.now(timezone.utc),
        duration_ms=1000,
        audio_path=str(foreign_audio),
        audio_size_bytes=foreign_audio.stat().st_size,
        transcription_status="pending",
        conversation_id=conversation.id,
    )
    db_session.add(segment)
    await db_session.commit()

    foreign_response = await client.delete(
        f"/api/conversations/{conversation.id}",
        headers=auth_headers,
    )
    missing_response = await client.delete(
        f"/api/conversations/{uuid.uuid4()}",
        headers=auth_headers,
    )

    assert foreign_response.status_code == 404
    assert missing_response.status_code == 404
    assert foreign_response.json() == missing_response.json()
    assert await db_session.get(Conversation, conversation.id) is not None
    assert await db_session.get(Segment, segment.id) is not None
    assert foreign_audio.exists()


@pytest.mark.asyncio
async def test_delete_conversation_treats_missing_audio_as_success(
    client,
    auth_headers,
    db_session: AsyncSession,
    tmp_path: Path,
) -> None:
    missing_audio = tmp_path / "already-gone.adpcm"
    conversation = Conversation(
        user_id=TEST_USER_ID,
        started_at=datetime.now(timezone.utc),
        analysis_status="completed",
    )
    db_session.add(conversation)
    await db_session.flush()
    db_session.add(
        Segment(
            user_id=TEST_USER_ID,
            received_at=datetime.now(timezone.utc),
            recorded_at=datetime.now(timezone.utc),
            duration_ms=1000,
            audio_path=str(missing_audio),
            audio_size_bytes=10,
            transcription_status="pending",
            conversation_id=conversation.id,
        )
    )
    await db_session.commit()

    response = await client.delete(
        f"/api/conversations/{conversation.id}",
        headers=auth_headers,
    )

    assert response.status_code == 204
    db_session.expire_all()
    assert await db_session.get(Conversation, conversation.id) is None


@pytest.mark.asyncio
async def test_stage_failure_restores_files_and_preserves_database(
    client,
    auth_headers,
    db_session: AsyncSession,
    tmp_path: Path,
) -> None:
    seeded = await _seed_complete_graph(db_session, tmp_path)
    storage = FailingRenameStorage(fail_on_call=2)
    app.dependency_overrides[get_conversation_storage] = lambda: storage
    try:
        response = await client.delete(
            f"/api/conversations/{seeded['target_id']}",
            headers=auth_headers,
        )
    finally:
        app.dependency_overrides.pop(get_conversation_storage, None)

    assert response.status_code == 503
    assert storage.rename_calls >= 2
    assert all(path.exists() for path in seeded["audio_paths"])
    assert list(tmp_path.glob(".echo-delete-*")) == []
    db_session.expire_all()
    assert await db_session.get(Conversation, seeded["target_id"]) is not None
    for segment_id in seeded["target_segment_ids"]:
        assert await db_session.get(Segment, segment_id) is not None


@pytest.mark.asyncio
async def test_commit_failure_rolls_back_and_restores_staged_audio(
    db_session: AsyncSession,
    tmp_path: Path,
) -> None:
    audio_path = tmp_path / "commit-failure.adpcm"
    audio_path.write_bytes(b"audio")
    conversation = Conversation(
        user_id=TEST_USER_ID,
        started_at=datetime.now(timezone.utc),
        analysis_status="completed",
    )
    db_session.add(conversation)
    await db_session.flush()
    db_session.add(
        Segment(
            user_id=TEST_USER_ID,
            received_at=datetime.now(timezone.utc),
            recorded_at=datetime.now(timezone.utc),
            duration_ms=1000,
            audio_path=str(audio_path),
            audio_size_bytes=audio_path.stat().st_size,
            transcription_status="pending",
            conversation_id=conversation.id,
        )
    )
    await db_session.commit()
    conversation_id = conversation.id
    failing_session = CommitFailingSession(db_session)

    with pytest.raises(RuntimeError, match="injected commit failure"):
        await delete_conversation(
            failing_session,
            TEST_USER_ID,
            conversation_id,
        )

    assert failing_session.rollback_calls == 1
    assert audio_path.exists()
    assert list(tmp_path.glob(".echo-delete-*")) == []
    assert await db_session.get(Conversation, conversation_id) is not None


@pytest.mark.asyncio
async def test_cleanup_failure_reports_warning_without_restoring_database(
    db_session: AsyncSession,
    tmp_path: Path,
) -> None:
    audio_path = tmp_path / "cleanup-failure.adpcm"
    audio_path.write_bytes(b"audio")
    conversation = Conversation(
        user_id=TEST_USER_ID,
        started_at=datetime.now(timezone.utc),
        analysis_status="completed",
    )
    db_session.add(conversation)
    await db_session.flush()
    db_session.add(
        Segment(
            user_id=TEST_USER_ID,
            received_at=datetime.now(timezone.utc),
            recorded_at=datetime.now(timezone.utc),
            duration_ms=1000,
            audio_path=str(audio_path),
            audio_size_bytes=audio_path.stat().st_size,
            transcription_status="pending",
            conversation_id=conversation.id,
        )
    )
    await db_session.commit()
    conversation_id = conversation.id

    result = await delete_conversation(
        db_session,
        TEST_USER_ID,
        conversation_id,
        FailingUnlinkStorage(),
    )

    assert len(result.cleanup_warnings) == 1
    assert not audio_path.exists()
    assert len(list(tmp_path.glob(".echo-delete-*"))) == 1
    assert await db_session.get(Conversation, conversation_id) is None
