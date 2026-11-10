"""Conversations API: list and detail endpoints."""

import uuid
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import BaseModel
from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.core.auth import get_current_user_id
from app.core.config import settings
from app.core.database import get_db
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.entity_mention import EntityMention
from app.models.photo import Photo
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.models.voice_profile import VoiceProfile
from app.services.conversation_deleter import (
    ConversationNotFoundError,
    ConversationStorage,
    ConversationStorageError,
    delete_conversation,
    get_conversation_storage,
)
from app.services.llm_openai import get_llm_query_service
from app.services.places import place_out, places_of
from app.services.temporal import conversation_overlaps
from app.services.topics import normalize_topics
from app.services.transcript_translation import translate_conversation

router = APIRouter(prefix="/conversations", tags=["conversations"])


# --- Schemas ---


class ConversationListItem(BaseModel):
    id: uuid.UUID
    title: str | None
    summary: str | None
    emoji: str | None
    started_at: datetime
    ended_at: datetime | None
    duration_s: int
    segment_count: int
    analysis_status: str
    # Still capturing: a new segment within the silence timeout would join it
    is_open: bool
    # Up to three people mentioned, in order of appearance
    people: list[str]
    task_count: int
    # Photos from the wearable camera taken during it, and the first one (Today's photo row)
    photo_count: int = 0
    photo_id: uuid.UUID | None = None
    # Where it mostly happened, when Places visited is on: {"visit_id", "name", "address"}
    place: dict | None = None

    model_config = {"from_attributes": True}


class ConversationListResponse(BaseModel):
    conversations: list[ConversationListItem]
    total: int


class EntityOut(BaseModel):
    id: uuid.UUID
    entity_type: str
    name: str
    content: str | None
    metadata_: dict
    # The transcript sentence the entity was extracted from, when known
    source_text: str | None = None

    model_config = {"from_attributes": True}


class TurnOut(BaseModel):
    """Who said what, in a segment where several voices spoke."""

    speaker_label: str
    speaker_name: str | None = None
    text: str


class TranscriptionOut(BaseModel):
    segment_id: uuid.UUID
    # None while the segment is still pending or failed
    text: str | None
    speaker_label: str | None
    status: str
    recorded_at: datetime
    # The recognised voice: its name, and "auto", "suggested" (ask) or "confirmed"
    speaker_name: str | None = None
    voice_match: str | None = None
    # The language it was heard in ("en"); None while pending
    language: str | None = None
    # Several voices in the segment: each one's turn, in order; None with one voice
    turns: list[TurnOut] | None = None

    model_config = {"from_attributes": True}


class PhotoOut(BaseModel):
    """A photo taken during the conversation (the image: GET /photos/{id}/image)."""

    id: uuid.UUID
    taken_at: datetime
    question: str | None
    answer: str | None
    description: str | None


class ConversationDetail(BaseModel):
    id: uuid.UUID
    title: str | None
    summary: str | None
    emoji: str | None
    started_at: datetime
    ended_at: datetime | None
    duration_s: int
    is_open: bool
    analysis_status: str
    transcriptions: list[TranscriptionOut]
    entities: list[EntityOut]
    photos: list[PhotoOut] = []
    place: dict | None = None

    model_config = {"from_attributes": True}


MAX_LISTED_PEOPLE = 3


def _duration_s(conversation: Conversation) -> int:
    end = conversation.ended_at or conversation.started_at
    return max(0, int((end - conversation.started_at).total_seconds()))


def _is_open(conversation: Conversation, now: datetime) -> bool:
    last = conversation.ended_at or conversation.started_at
    return last >= now - timedelta(milliseconds=settings.silence_timeout_ms)


async def _people_and_tasks(
    db: AsyncSession, conversation_ids: list[uuid.UUID]
) -> tuple[dict[uuid.UUID, list[str]], dict[uuid.UUID, int]]:
    """People (in order of appearance) and task counts mentioned in each conversation."""
    people: dict[uuid.UUID, list[str]] = defaultdict(list)
    tasks: dict[uuid.UUID, int] = defaultdict(int)
    if not conversation_ids:
        return people, tasks
    kinds = ("person", "task")
    mentioned = await db.execute(
        select(
            EntityMention.conversation_id,
            Entity.id,
            Entity.entity_type,
            Entity.name,
            EntityMention.created_at,
        )
        .join(Entity, Entity.id == EntityMention.entity_id)
        .where(EntityMention.conversation_id.in_(conversation_ids))
        .where(Entity.entity_type.in_(kinds))
    )
    # Entities written without a mention still count for the conversation they point at
    pointing = await db.execute(
        select(
            Entity.conversation_id, Entity.id, Entity.entity_type, Entity.name, Entity.created_at
        )
        .where(Entity.conversation_id.in_(conversation_ids))
        .where(Entity.entity_type.in_(kinds))
    )
    seen: set[tuple[uuid.UUID, uuid.UUID]] = set()
    rows = sorted([*mentioned.all(), *pointing.all()], key=lambda row: row[4])
    for conversation_id, entity_id, entity_type, name, _ in rows:
        if (conversation_id, entity_id) in seen:
            continue
        seen.add((conversation_id, entity_id))
        if entity_type == "task":
            tasks[conversation_id] += 1
        elif name not in people[conversation_id]:
            people[conversation_id].append(name)
    return people, tasks


def with_segment_counts(*conditions):
    """Conversations matching `conditions` with their segment count, newest first."""
    return (
        select(Conversation, func.count(Segment.id).label("segment_count"))
        .outerjoin(Segment, Segment.conversation_id == Conversation.id)
        .where(*conditions)
        .group_by(Conversation.id)
        .order_by(Conversation.started_at.desc())
    )


async def list_items(db: AsyncSession, rows) -> list[ConversationListItem]:
    """List items for (conversation, segment_count) rows, with their people and task counts."""
    ids = [conv.id for conv, _ in rows]
    people, tasks = await _people_and_tasks(db, ids)
    photos = await _photo_counts(db, ids)
    now = datetime.now(timezone.utc)
    where = await conversation_places(db, [conv for conv, _ in rows], now)
    return [
        ConversationListItem(
            id=conv.id,
            title=conv.title,
            summary=conv.summary,
            emoji=conv.emoji,
            started_at=conv.started_at,
            ended_at=conv.ended_at,
            duration_s=_duration_s(conv),
            segment_count=segment_count,
            analysis_status=conv.analysis_status,
            is_open=_is_open(conv, now),
            people=people[conv.id][:MAX_LISTED_PEOPLE],
            task_count=tasks[conv.id],
            photo_count=photos.get(conv.id, (0, None))[0],
            photo_id=photos.get(conv.id, (0, None))[1],
            place=where.get(conv.id),
        )
        for conv, segment_count in rows
    ]


async def conversation_places(
    db: AsyncSession, conversations: list[Conversation], now: datetime
) -> dict[uuid.UUID, dict]:
    """Per conversation, the place of the visit it mostly happened in (none without
    visits). Read here, for the app; outside assistants' tools leave it out."""
    found: dict[uuid.UUID, dict] = {}
    by_user: dict[uuid.UUID, list[Conversation]] = defaultdict(list)
    for conv in conversations:
        by_user[conv.user_id].append(conv)
    for user_id, own in by_user.items():
        visits = await places_of(
            db, user_id, [(c.id, c.started_at, c.ended_at) for c in own], now=now
        )
        found.update({cid: place_out(visit) for cid, visit in visits.items()})
    return found


async def _photo_counts(
    db: AsyncSession, ids: list[uuid.UUID]
) -> dict[uuid.UUID, tuple[int, uuid.UUID]]:
    """Per conversation: how many photos have an image, and the first one taken."""
    if not ids:
        return {}
    rows = await db.execute(
        select(Photo.conversation_id, Photo.id)
        .where(Photo.conversation_id.in_(ids), Photo.image_sha256.isnot(None))
        .order_by(Photo.created_at)
    )
    photos: dict[uuid.UUID, tuple[int, uuid.UUID]] = {}
    for conversation_id, photo_id in rows.all():
        count, first = photos.get(conversation_id, (0, photo_id))
        photos[conversation_id] = (count + 1, first)
    return photos


def conversation_entities(conversation_id: uuid.UUID):
    """Entities mentioned in a conversation, with the sentence they came from there.

    Includes entities that point at it without a mention (written before mentions).
    """
    mention_text = aliased(Transcription)
    entity_text = aliased(Transcription)
    mention = aliased(EntityMention)
    return (
        select(Entity, func.coalesce(mention_text.text, entity_text.text))
        .outerjoin(
            mention,
            and_(mention.entity_id == Entity.id, mention.conversation_id == conversation_id),
        )
        .outerjoin(mention_text, mention_text.id == mention.transcription_id)
        .outerjoin(entity_text, entity_text.id == Entity.source_transcription_id)
        .where(or_(mention.id.is_not(None), Entity.conversation_id == conversation_id))
        .order_by(func.coalesce(mention.created_at, Entity.created_at))
    )


# --- Endpoints ---


@router.get("", response_model=ConversationListResponse)
async def list_conversations(
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    topic: str | None = None,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """List the user's conversations, most recent first; optionally those overlapping a period."""
    conditions = [
        Conversation.user_id == user_id,
        *conversation_overlaps(date_from, date_to),
    ]
    if topic is not None:
        normalized = normalize_topics([topic], [])
        conditions.append(Conversation.topics.any(normalized[0] if normalized else ""))
    total = (
        await db.execute(select(func.count(Conversation.id)).where(*conditions))
    ).scalar() or 0

    query = with_segment_counts(*conditions).offset(offset).limit(limit)
    rows = (await db.execute(query)).all()
    return ConversationListResponse(conversations=await list_items(db, rows), total=total)


@router.get("/{conversation_id}", response_model=ConversationDetail)
async def get_conversation(
    conversation_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """A conversation with its segments (pending ones too) and the entities extracted from it."""
    conversation = (
        await db.execute(
            select(Conversation)
            .where(Conversation.id == conversation_id)
            .where(Conversation.user_id == user_id)
        )
    ).scalar_one_or_none()
    if conversation is None:
        raise HTTPException(status_code=404, detail="Conversation not found")

    segment_rows = await db.execute(
        select(
            Segment.id,
            Segment.recorded_at,
            Segment.transcription_status,
            Transcription.text,
            Transcription.speaker_label,
            Transcription.language,
            Segment.voice_match,
            Segment.voice_group,
            VoiceProfile.name.label("speaker_name"),
            Transcription.turns,
        )
        .outerjoin(Transcription, Transcription.segment_id == Segment.id)
        .outerjoin(VoiceProfile, VoiceProfile.id == Segment.voice_profile_id)
        .where(Segment.conversation_id == conversation_id)
        .order_by(Segment.recorded_at)
    )
    rows = segment_rows.all()
    names = {}
    if any(row.turns for row in rows):
        names = {
            str(profile_id): name
            for profile_id, name in await db.execute(
                select(VoiceProfile.id, VoiceProfile.name).where(VoiceProfile.user_id == user_id)
            )
        }
    transcriptions = [
        TranscriptionOut(
            segment_id=row.id,
            text=row.text,
            speaker_label=row.speaker_label,
            status=row.transcription_status,
            recorded_at=row.recorded_at,
            # A named voice, else an unknown one told apart from the others ("Person 2")
            speaker_name=row.speaker_name
            or (f"Person {row.voice_group}" if row.voice_group else None),
            voice_match=row.voice_match if row.speaker_name else None,
            language=row.language,
            turns=[
                TurnOut(
                    speaker_label=turn["speaker"],
                    speaker_name=names.get(turn["profile_id"])
                    or (f"Person {turn['group']}" if turn["group"] else None),
                    text=turn["text"],
                )
                for turn in row.turns
            ] if row.turns else None,
        )
        for row in rows
    ]

    entity_rows = await db.execute(conversation_entities(conversation_id))
    entities = [
        EntityOut(
            id=e.id,
            entity_type=e.entity_type,
            name=e.name,
            content=e.content,
            metadata_=e.metadata_,
            source_text=source_text,
        )
        for e, source_text in entity_rows.all()
    ]

    photo_rows = await db.execute(
        select(Photo)
        .where(Photo.conversation_id == conversation_id, Photo.image_sha256.isnot(None))
        .order_by(func.coalesce(Photo.captured_at, Photo.created_at))
    )
    photos = [
        PhotoOut(
            id=p.id,
            taken_at=p.captured_at or p.created_at,
            question=p.question,
            answer=p.answer,
            description=p.description,
        )
        for p in photo_rows.scalars().all()
    ]

    return ConversationDetail(
        id=conversation.id,
        title=conversation.title,
        summary=conversation.summary,
        emoji=conversation.emoji,
        started_at=conversation.started_at,
        ended_at=conversation.ended_at,
        duration_s=_duration_s(conversation),
        is_open=_is_open(conversation, datetime.now(timezone.utc)),
        analysis_status=conversation.analysis_status,
        transcriptions=transcriptions,
        entities=entities,
        photos=photos,
        place=(await conversation_places(db, [conversation], datetime.now(timezone.utc))).get(
            conversation.id
        ),
    )


class TranslationOut(BaseModel):
    # The user's language, which the lines are translated into
    language: str
    # By segment id: the lines heard in another language
    lines: dict[str, str]


@router.post("/{conversation_id}/translate", response_model=TranslationOut)
async def translate_conversation_endpoint(
    conversation_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The conversation's lines in another language, translated into the user's (each
    translated once, then kept)."""
    owned = await db.scalar(
        select(Conversation.id).where(
            Conversation.id == conversation_id, Conversation.user_id == user_id
        )
    )
    if owned is None:
        raise HTTPException(status_code=404, detail="Conversation not found")
    language, lines = await translate_conversation(
        db, user_id, conversation_id, get_llm_query_service()
    )
    return TranslationOut(language=language, lines=lines)


@router.delete("/{conversation_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_conversation_endpoint(
    conversation_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
    storage: ConversationStorage = Depends(get_conversation_storage),
) -> Response:
    """Permanently delete an owned conversation and its stored audio."""
    try:
        await delete_conversation(db, user_id, conversation_id, storage)
    except ConversationNotFoundError:
        raise HTTPException(status_code=404, detail="Conversation not found")
    except ConversationStorageError:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Conversation audio storage is temporarily unavailable",
        )

    return Response(status_code=status.HTTP_204_NO_CONTENT)
