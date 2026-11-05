"""Chat sessions API: persistent conversation history with the assistant."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.voice import get_or_create_voice_session
from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.assistant import Assistant
from app.models.chat_session import ChatSession

router = APIRouter(prefix="/chat-sessions", tags=["chat-sessions"])


class ChatMessage(BaseModel):
    role: str  # "user" | "assistant"
    content: str
    timestamp: str | None = None
    pending_action: dict | None = None
    photo_id: str | None = None  # a photo from the wearable camera: GET /photos/{id}/image
    citations: list[dict] | None = None  # web pages the answer cites: {"title", "url"}
    # Where a question came from: "voice", "chat" (typed) or "camera" (the app's button);
    # none on messages written before it was kept
    source: str | None = None
    # A photo's answer: the date or time it shows, for "Remind me" (ISO, local)
    when: str | None = None
    # A routine's run (the routines worker): its id and schedule ("Every day at 07:00")
    routine_id: str | None = None
    routine_schedule: str | None = None
    # A follow-up question about a photo, and its answer
    about_photo_id: str | None = None
    # What the answer saved or changed in Saved: {"id", "title", "list", "address"}
    saved: list[dict] | None = None
    # What an assistant added to its notes in this answer
    noted: list[str] | None = None


class ChatSessionSummary(BaseModel):
    id: uuid.UUID
    title: str | None
    message_count: int
    kind: str
    created_at: datetime
    updated_at: datetime
    # The assistant the chat is with; none: plain Echo
    assistant_id: uuid.UUID | None = None
    assistant_name: str | None = None
    assistant_emoji: str | None = None

    model_config = {"from_attributes": True}


class ChatSessionDetail(BaseModel):
    id: uuid.UUID
    title: str | None
    kind: str = "chat"
    messages: list[ChatMessage]
    created_at: datetime
    updated_at: datetime
    assistant_id: uuid.UUID | None = None
    assistant_name: str | None = None
    assistant_emoji: str | None = None

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
    assistants = await _assistants_of(db, sessions)

    items = [
        ChatSessionSummary(
            id=s.id,
            title=s.title,
            message_count=len(s.messages),
            kind=s.kind,
            created_at=s.created_at,
            updated_at=s.updated_at,
            **_assistant_fields(assistants.get(s.assistant_id)),
        )
        for s in sessions
    ]

    return ChatSessionListResponse(items=items, count=len(items))


def _assistant_fields(assistant: Assistant | None) -> dict:
    if assistant is None:
        return {}
    return {
        "assistant_id": assistant.id,
        "assistant_name": assistant.name,
        "assistant_emoji": assistant.emoji,
    }


async def _assistants_of(db: AsyncSession, sessions: list[ChatSession]) -> dict:
    ids = {s.assistant_id for s in sessions if s.assistant_id is not None}
    if not ids:
        return {}
    rows = await db.scalars(select(Assistant).where(Assistant.id.in_(ids)))
    return {a.id: a for a in rows}


def _detail(session: ChatSession, assistant: Assistant | None = None) -> ChatSessionDetail:
    return ChatSessionDetail(
        id=session.id,
        title=session.title,
        kind=session.kind,
        messages=[ChatMessage(**m) for m in session.messages],
        created_at=session.created_at,
        updated_at=session.updated_at,
        **_assistant_fields(assistant),
    )


@router.get("/thread", response_model=ChatSessionDetail)
async def get_thread(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The thread with Echo (the voice session), created on first use: what Ask opens.

    Voice requests, photos and routine answers land here; typed questions too, unless the
    user starts a new chat.
    """
    session = await get_or_create_voice_session(db, user_id)
    await db.commit()
    return _detail(session)


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

    assistant = (
        await db.get(Assistant, session.assistant_id) if session.assistant_id else None
    )
    return _detail(session, assistant)


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
