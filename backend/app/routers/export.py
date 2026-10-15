"""GET /export: everything Echo keeps about the user, as one JSON document.

For the user to keep or move their data. Vectors (embeddings, voice fingerprints) are
left out: they are numbers only a model can read. Photo images are left out too (they
are served one by one by GET /photos/{id}/image); their text is in.
"""

import json
import uuid
from collections import defaultdict
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.chat_session import ChatSession
from app.models.conversation import Conversation
from app.models.digest import Digest
from app.models.entity import Entity
from app.models.photo import Photo
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.models.voice_profile import VoiceProfile
from app.models.weekly_digest import WeeklyDigest

router = APIRouter(tags=["export"])

EXPORT_VERSION = 1


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


async def export_user_data(db: AsyncSession, user_id: uuid.UUID) -> dict:
    conversations = (
        await db.execute(
            select(Conversation)
            .where(Conversation.user_id == user_id)
            .order_by(Conversation.started_at)
        )
    ).scalars().all()

    lines: dict[uuid.UUID, list[dict]] = defaultdict(list)
    for segment, text, speaker in (
        await db.execute(
            select(Segment, Transcription.text, Transcription.speaker_label)
            .join(Transcription, Transcription.segment_id == Segment.id)
            .where(Segment.user_id == user_id)
            .order_by(Segment.recorded_at)
        )
    ).all():
        lines[segment.conversation_id].append(
            {
                "recorded_at": _iso(segment.recorded_at),
                "speaker": speaker or segment.speaker,
                "text": text,
            }
        )

    photos: dict[uuid.UUID | None, list[dict]] = defaultdict(list)
    for photo in (
        await db.execute(
            select(Photo).where(Photo.user_id == user_id).order_by(Photo.created_at)
        )
    ).scalars():
        photos[photo.conversation_id].append(
            {
                "id": str(photo.id),
                "taken_at": _iso(photo.captured_at or photo.created_at),
                "question": photo.question,
                "answer": photo.answer,
                "description": photo.description,
                "has_image": photo.image_sha256 is not None,
            }
        )

    entities = (
        await db.execute(
            select(Entity).where(Entity.user_id == user_id).order_by(Entity.created_at)
        )
    ).scalars().all()

    sessions = (
        await db.execute(
            select(ChatSession)
            .where(ChatSession.user_id == user_id)
            .order_by(ChatSession.created_at)
        )
    ).scalars().all()
    digests = (
        await db.execute(
            select(Digest).where(Digest.user_id == user_id).order_by(Digest.digest_date)
        )
    ).scalars().all()
    weeks = (
        await db.execute(
            select(WeeklyDigest)
            .where(WeeklyDigest.user_id == user_id)
            .order_by(WeeklyDigest.week_start)
        )
    ).scalars().all()
    voices = (
        await db.execute(select(VoiceProfile).where(VoiceProfile.user_id == user_id))
    ).scalars().all()

    return {
        "format": "echo-export",
        "version": EXPORT_VERSION,
        "exported_at": _iso(datetime.now(timezone.utc)),
        "conversations": [
            {
                "id": str(c.id),
                "title": c.title,
                "summary": c.summary,
                "emoji": c.emoji,
                "started_at": _iso(c.started_at),
                "ended_at": _iso(c.ended_at),
                "transcript": lines.get(c.id, []),
                "photos": photos.get(c.id, []),
            }
            for c in conversations
        ],
        "entities": [
            {
                "id": str(e.id),
                "type": e.entity_type,
                "name": e.name,
                "content": e.content,
                "metadata": e.metadata_,
                "conversation_id": str(e.conversation_id) if e.conversation_id else None,
                "created_at": _iso(e.created_at),
            }
            for e in entities
        ],
        "chats": [
            {
                "id": str(s.id),
                "title": s.title,
                "kind": s.kind,
                "messages": s.messages,
                "created_at": _iso(s.created_at),
            }
            for s in sessions
        ],
        "daily_summaries": [
            {"date": d.digest_date.isoformat(), "summary": d.summary} for d in digests
        ],
        "weekly_summaries": [
            {
                "week_start": w.week_start.isoformat(),
                "summary": w.summary,
                "highlights": w.highlights,
            }
            for w in weeks
        ],
        "photos_outside_conversations": photos.get(None, []),
        "voices": [
            {"name": v.name, "is_self": v.is_self, "sample_count": v.sample_count}
            for v in voices
        ],
    }


@router.get("/export")
async def export(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Everything as JSON, offered as a file to save."""
    data = await export_user_data(db, user_id)
    day = datetime.now(timezone.utc).date().isoformat()
    return Response(
        content=json.dumps(data, ensure_ascii=False, indent=1, default=str),
        media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="echo-export-{day}.json"'},
    )
