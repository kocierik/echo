"""Conversations API: list and detail endpoints."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.segment import Segment
from app.models.transcription import Transcription

router = APIRouter(prefix="/conversations", tags=["conversations"])


# --- Schemas ---


class ConversationListItem(BaseModel):
    id: uuid.UUID
    title: str | None
    summary: str | None
    started_at: datetime
    ended_at: datetime | None
    segment_count: int
    analysis_status: str

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

    model_config = {"from_attributes": True}


class TranscriptionOut(BaseModel):
    text: str
    recorded_at: datetime

    model_config = {"from_attributes": True}


class ConversationDetail(BaseModel):
    id: uuid.UUID
    title: str | None
    summary: str | None
    started_at: datetime
    ended_at: datetime | None
    analysis_status: str
    transcriptions: list[TranscriptionOut]
    entities: list[EntityOut]

    model_config = {"from_attributes": True}


# --- Endpoints ---


@router.get("", response_model=ConversationListResponse)
async def list_conversations(
    limit: int = 20,
    offset: int = 0,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """List all conversations for the current user, most recent first."""
    # Count total
    count_query = (
        select(func.count(Conversation.id))
        .where(Conversation.user_id == user_id)
    )
    total = (await db.execute(count_query)).scalar() or 0

    # Fetch conversations with segment count
    query = (
        select(
            Conversation,
            func.count(Segment.id).label("segment_count"),
        )
        .outerjoin(Segment, Segment.conversation_id == Conversation.id)
        .where(Conversation.user_id == user_id)
        .group_by(Conversation.id)
        .order_by(Conversation.started_at.desc())
        .offset(offset)
        .limit(limit)
    )

    result = await db.execute(query)
    rows = result.all()

    items = [
        ConversationListItem(
            id=conv.id,
            title=conv.title,
            summary=conv.summary,
            started_at=conv.started_at,
            ended_at=conv.ended_at,
            segment_count=seg_count,
            analysis_status=conv.analysis_status,
        )
        for conv, seg_count in rows
    ]

    return ConversationListResponse(conversations=items, total=total)


@router.get("/{conversation_id}", response_model=ConversationDetail)
async def get_conversation(
    conversation_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Get details of a specific conversation including transcriptions and entities."""
    # Fetch conversation
    query = (
        select(Conversation)
        .where(Conversation.id == conversation_id)
        .where(Conversation.user_id == user_id)
    )
    result = await db.execute(query)
    conversation = result.scalar_one_or_none()

    if conversation is None:
        raise HTTPException(status_code=404, detail="Conversation not found")

    # Fetch transcriptions in order
    trans_query = (
        select(Transcription.text, Segment.recorded_at)
        .join(Segment, Segment.id == Transcription.segment_id)
        .where(Segment.conversation_id == conversation_id)
        .order_by(Segment.recorded_at)
    )
    trans_result = await db.execute(trans_query)
    transcriptions = [
        TranscriptionOut(text=row.text, recorded_at=row.recorded_at)
        for row in trans_result.all()
    ]

    # Fetch entities
    ent_query = (
        select(Entity)
        .where(Entity.conversation_id == conversation_id)
        .order_by(Entity.created_at)
    )
    ent_result = await db.execute(ent_query)
    entities = [
        EntityOut(
            id=e.id,
            entity_type=e.entity_type,
            name=e.name,
            content=e.content,
            metadata_=e.metadata_,
        )
        for e in ent_result.scalars().all()
    ]

    return ConversationDetail(
        id=conversation.id,
        title=conversation.title,
        summary=conversation.summary,
        started_at=conversation.started_at,
        ended_at=conversation.ended_at,
        analysis_status=conversation.analysis_status,
        transcriptions=transcriptions,
        entities=entities,
    )
