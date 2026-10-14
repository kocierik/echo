"""Database rows for API tests: conversations with segments and transcriptions, entities."""

import uuid
from datetime import datetime, timedelta

from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Conversation, Entity, Segment, Transcription
from tests.conftest import TEST_USER_ID


async def make_conversation(
    db: AsyncSession,
    *,
    started_at: datetime,
    minutes: int = 10,
    title: str | None = "Lunch with Ada",
    summary: str | None = "Ada proposes the Atlas project.",
    emoji: str | None = "🍝",
    texts: tuple[str | None, ...] = ("[Tu] Domani pranzo con Ada.",),
    user_id: uuid.UUID = TEST_USER_ID,
) -> tuple[Conversation, list[Transcription | None]]:
    conversation = Conversation(
        user_id=user_id,
        title=title,
        summary=summary,
        emoji=emoji,
        started_at=started_at,
        ended_at=started_at + timedelta(minutes=minutes),
        analysis_status="completed",
    )
    db.add(conversation)
    await db.flush()
    transcriptions: list[Transcription | None] = []
    for index, text in enumerate(texts):
        segment = Segment(
            user_id=user_id,
            received_at=started_at,
            recorded_at=started_at + timedelta(seconds=index * 10),
            duration_ms=5000,
            audio_path=f"/tmp/{uuid.uuid4()}.adpcm",
            audio_size_bytes=10,
            transcription_status="completed" if text is not None else "pending",
            conversation_id=conversation.id,
        )
        db.add(segment)
        await db.flush()
        if text is None:
            transcriptions.append(None)
            continue
        transcription = Transcription(
            segment_id=segment.id,
            text=text,
            speaker_label="self",
            language="it",
            stt_provider="test",
            stt_model="test",
        )
        db.add(transcription)
        await db.flush()
        transcriptions.append(transcription)
    return conversation, transcriptions


def make_entity(
    conversation: Conversation,
    entity_type: str,
    name: str,
    *,
    source: Transcription | None = None,
    metadata: dict | None = None,
    content: str | None = None,
) -> Entity:
    return Entity(
        user_id=conversation.user_id,
        entity_type=entity_type,
        name=name,
        content=content,
        metadata_=metadata or {},
        conversation_id=conversation.id,
        source_transcription_id=source.id if source else None,
    )
