"""Chat sessions API: persistent conversation history with the assistant."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.chat_session import ChatSession

router = APIRouter(prefix="/chat-sessions", tags=["chat-sessions"])


class ChatMessage(BaseModel):
    role: str  # "user" | "assistant"
    content: str
    timestamp: str | None = None
    pending_action: dict | None = None
    photo_id: str | None = None  # a photo from the wearable camera: GET /photos/{id}/image
    citations: list[dict] | None = None  # web pages the answer cites: {"title", "url"}


class ChatSessionSummary(BaseModel):
    id: uuid.UUID
    title: str | None
    message_count: int
    kind: str
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class ChatSessionDetail(BaseModel):
    id: uuid.UUID
    title: str | None
    messages: list[ChatMessage]
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class ChatSessionListResponse(BaseModel):
    items: list[ChatSessionSummary]
    count: int


def order_sessions(sessions: list[ChatSession]) -> list[ChatSession]:
    """Voice sessions first, then the most recently updated."""
    by_recency = sorted(sessions, key=lambda s: s.updated_at, reverse=True)
    return sorted(by_recency, key=lambda s: s.kind != "voice")


@router.get("", response_model=ChatSessionListResponse)
async def list_chat_sessions(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """List chat sessions for the user: voice first, then most recent first."""
    query = (
        select(ChatSession)
        .where(ChatSession.user_id == user_id)
        .order_by((ChatSession.kind == "voice").desc(), ChatSession.updated_at.desc())
        .limit(50)
    )
    result = await db.execute(query)
    sessions = order_sessions(list(result.scalars().all()))

    items = [
        ChatSessionSummary(
            id=s.id,
            title=s.title,
            message_count=len(s.messages),
            kind=s.kind,
            created_at=s.created_at,
            updated_at=s.updated_at,
        )
        for s in sessions
    ]

    return ChatSessionListResponse(items=items, count=len(items))


@router.get("/{session_id}", response_model=ChatSessionDetail)
async def get_chat_session(
    session_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Get a specific chat session with full message history."""
    query = (
        select(ChatSession)
        .where(ChatSession.id == session_id)
        .where(ChatSession.user_id == user_id)
    )
    result = await db.execute(query)
    session = result.scalar_one_or_none()

    if session is None:
        raise HTTPException(status_code=404, detail="Chat session not found")

    return ChatSessionDetail(
        id=session.id,
        title=session.title,
        messages=[ChatMessage(**m) for m in session.messages],
        created_at=session.created_at,
        updated_at=session.updated_at,
    )


@router.delete("/{session_id}", status_code=204)
async def delete_chat_session(
    session_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Delete a chat session."""
    query = (
        select(ChatSession)
        .where(ChatSession.id == session_id)
        .where(ChatSession.user_id == user_id)
    )
    result = await db.execute(query)
    session = result.scalar_one_or_none()

    if session is None:
        raise HTTPException(status_code=404, detail="Chat session not found")

    await db.delete(session)
