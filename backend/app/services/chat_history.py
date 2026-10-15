"""Chat history: the recent turns in Redis (follow-up context) and the complete session in
Postgres (the chat list and history in the app). Shared by chat, voice and action outcomes.
"""

import json
import uuid
from datetime import datetime, timezone

import redis.asyncio as aioredis
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.chat_session import ChatSession

SESSION_TTL_SECONDS = 30 * 60
# Max history messages to keep (to avoid token explosion)
MAX_HISTORY_MESSAGES = 20


async def get_session_history(
    redis_client: aioredis.Redis, session_id: str
) -> list[dict]:
    """Retrieve conversation history from Redis."""
    raw = await redis_client.get(f"session:{session_id}")
    if raw is None:
        return []
    return json.loads(raw)


async def save_session_history(
    redis_client: aioredis.Redis, session_id: str, history: list[dict]
):
    """Save conversation history to Redis with TTL refresh."""
    # Trim to max history
    if len(history) > MAX_HISTORY_MESSAGES:
        history = history[-MAX_HISTORY_MESSAGES:]
    await redis_client.set(
        f"session:{session_id}",
        json.dumps(history),
        ex=SESSION_TTL_SECONDS,
    )


async def load_persisted_history(
    db: AsyncSession, user_id: uuid.UUID, session_uuid: uuid.UUID
) -> list[dict]:
    """Load the most recent messages of a persisted session as LLM history."""
    result = await db.execute(
        select(ChatSession.messages)
        .where(ChatSession.id == session_uuid)
        .where(ChatSession.user_id == user_id)
    )
    messages = result.scalar_one_or_none() or []
    return [
        {
            "role": m["role"],
            "content": m["content"],
            **({"actions": True} if m.get("actions") else {}),
        }
        for m in messages[-MAX_HISTORY_MESSAGES:]
    ]


async def record_turn(
    redis_client: aioredis.Redis,
    db: AsyncSession,
    user_id: uuid.UUID,
    session_id: str,
    history: list[dict],
    question: str,
    answer: str,
    assistant_extra: dict | None = None,
):
    """Append one question/answer turn to the Redis context and the Postgres session."""
    turn = [
        {"role": "user", "content": question},
        {"role": "assistant", "content": answer, **(assistant_extra or {})},
    ]
    history.extend(turn)
    await save_session_history(redis_client, session_id, history)
    await persist_chat_session(db, user_id, session_id, turn)


async def persist_chat_session(
    db: AsyncSession, user_id: uuid.UUID, session_id: str, new_messages: list[dict]
):
    """Append new messages to the chat session in Postgres (complete history).

    The Redis history is trimmed and expires, so it must never overwrite the
    persisted messages: only the new turn is appended here.
    """
    session_uuid = uuid.UUID(session_id)

    # Try to find existing session
    result = await db.execute(
        select(ChatSession).where(ChatSession.id == session_uuid)
    )
    chat_session = result.scalar_one_or_none()

    if chat_session is None:
        # Create new session — generate title from first user message
        first_question = next(
            (m["content"] for m in new_messages if m["role"] == "user"), "Nuova chat"
        )
        title = first_question[:80]

        chat_session = ChatSession(
            id=session_uuid,
            user_id=user_id,
            title=title,
            messages=list(new_messages),
        )
        db.add(chat_session)
    elif chat_session.user_id != user_id:
        raise HTTPException(status_code=404, detail="Chat session not found")
    else:
        # Reassign (not mutate) so SQLAlchemy detects the JSONB change
        chat_session.messages = [*chat_session.messages, *new_messages]
        chat_session.updated_at = datetime.now(timezone.utc)
