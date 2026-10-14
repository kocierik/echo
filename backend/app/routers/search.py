"""Search across the memory: conversations (title, summary, transcript) and entities."""

import uuid

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.routers.conversations import (
    ConversationListItem,
    EntityOut,
    list_items,
    with_segment_counts,
)

router = APIRouter(prefix="/search", tags=["search"])


class SearchEntity(EntityOut):
    conversation_id: uuid.UUID | None


class SearchResponse(BaseModel):
    conversations: list[ConversationListItem]
    entities: list[SearchEntity]


def _contains(query: str) -> str:
    """ILIKE pattern matching `query` literally (its % and _ are not wildcards)."""
    escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


@router.get("", response_model=SearchResponse)
async def search(
    q: str = Query(..., min_length=2, max_length=200),
    limit: int = Query(20, ge=1, le=50),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Case-insensitive text search, newest first. Words are matched as one phrase."""
    pattern = _contains(q.strip())

    in_transcript = (
        select(Segment.conversation_id)
        .join(Transcription, Transcription.segment_id == Segment.id)
        .where(Segment.user_id == user_id)
        .where(Transcription.text.ilike(pattern))
    )
    conversation_rows = (
        await db.execute(
            with_segment_counts(
                Conversation.user_id == user_id,
                or_(
                    Conversation.title.ilike(pattern),
                    Conversation.summary.ilike(pattern),
                    Conversation.id.in_(in_transcript),
                ),
            ).limit(limit)
        )
    ).all()

    entity_rows = await db.execute(
        select(Entity, Transcription.text)
        .outerjoin(Transcription, Transcription.id == Entity.source_transcription_id)
        .where(Entity.user_id == user_id)
        .where(or_(Entity.name.ilike(pattern), Entity.content.ilike(pattern)))
        .order_by(Entity.updated_at.desc())
        .limit(limit)
    )

    return SearchResponse(
        conversations=await list_items(db, conversation_rows),
        entities=[
            SearchEntity(
                id=e.id,
                entity_type=e.entity_type,
                name=e.name,
                content=e.content,
                metadata_=e.metadata_,
                source_text=source_text,
                conversation_id=e.conversation_id,
            )
            for e, source_text in entity_rows.all()
        ],
    )
