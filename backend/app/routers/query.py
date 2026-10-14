"""Query API: natural language search over personal memory with RAG."""

import json
import logging
import re
import uuid
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime, timezone

import redis.asyncio as aioredis
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from slowapi import Limiter
from slowapi.util import get_remote_address
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.agent import run_action_agent
from app.actions.audit import AuditRecorder, restore_audit
from app.actions.availability import route_request
from app.actions.composio_provider import get_action_provider
from app.actions.provider import ActionProviderError
from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.chat_session import ChatSession
from app.services.embedding_openai import get_embedding_service
from app.services.language import detect_language
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_query_service
from app.services.memory_retrieval import retrieve_memory_context
from app.services.temporal import DateRange, extract_date_range

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/query", tags=["query"])

limiter = Limiter(key_func=get_remote_address)

# Session TTL: 30 minutes of inactivity
SESSION_TTL_SECONDS = 30 * 60
# Max history messages to keep (to avoid token explosion)
MAX_HISTORY_MESSAGES = 20
# A client_request_id is answered once: the marker holds "processing", then the response.
REQUEST_MARKER_TTL_SECONDS = 10 * 60
_PROCESSING = "processing"
# Stored for a request whose action agent failed: tools may have run, so a retry of the
# same client_request_id gets this answer instead of running them again.
_UNFINISHED = {
    "en": (
        "I couldn't finish this request. Some steps may have run — check Settings → "
        "Automations → Activity before asking again."
    ),
    "it": (
        "Non sono riuscito a completare la richiesta. Alcuni passaggi potrebbero essere "
        "stati eseguiti: controlla Impostazioni → Automazioni → Attività prima di riprovare."
    ),
}


@dataclass
class _Progress:
    """How far one request got, for the retry marker when it fails."""

    session_id: str | None = None
    agent_started: bool = False


class QueryRequest(BaseModel):
    question: str
    top_k: int = 5
    date_from: datetime | None = None
    date_to: datetime | None = None
    session_id: str | None = None
    # Same id for a retry of the same user message: the answer is not computed twice.
    client_request_id: str | None = Field(default=None, max_length=100)


class SourceChunk(BaseModel):
    conversation_id: uuid.UUID
    chunk_id: uuid.UUID
    text: str
    similarity: float

    model_config = {"from_attributes": True}


class PendingActionOut(BaseModel):
    id: uuid.UUID
    summary: str
    status: str
    expires_at: datetime


class QueryResponse(BaseModel):
    answer: str
    sources: list[SourceChunk]
    session_id: str
    date_filter: dict | None = None
    pending_action: PendingActionOut | None = None


# Words that may introduce a request on a connected tool (prefix match, IT + EN).
# Messages without them skip the provider and the intent check and go straight to RAG.
# With them, one intent check (app.actions.availability.route_request) decides.
_TOOL_HINT = re.compile(
    r"\b(calendar|calendario|agenda|event|appuntament|appointment|riunion|meeting|"
    r"call\b|impegn|programma|schedul|fiss|prenot|organizz|segna|crea|aggiung|add\b|"
    r"book|spost|rimand|anticip|posticip|resched|move|cancell|elimin|annull|delete|"
    r"remove|cancel|rinomin|rename|modific|cambi|change|"
    r"e?-?mail|posta|gmail|slack|telegram|messag|todoist|task|notion|nota\b|note\b|"
    r"inbox)",
    re.IGNORECASE,
)

def might_need_tools(question: str, history: list[dict]) -> bool:
    """Cheap pre-check before spending a provider call and the intent check."""
    if _TOOL_HINT.search(question):
        return True
    last_assistant = next(
        (m for m in reversed(history) if m.get("role") == "assistant"), None
    )
    return bool(last_assistant and last_assistant.get("actions"))


async def _get_session_history(
    redis_client: aioredis.Redis, session_id: str
) -> list[dict]:
    """Retrieve conversation history from Redis."""
    raw = await redis_client.get(f"session:{session_id}")
    if raw is None:
        return []
    return json.loads(raw)


async def _save_session_history(
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


@router.post("", response_model=QueryResponse)
@limiter.limit("20/minute")
async def query_memory(
    request: Request,
    body: QueryRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Query the user's memory using natural language.

    Supports multi-turn follow-up via session_id:
    - First request: omit session_id → a new session is created
    - Follow-up: include session_id from previous response → continues the conversation

    Performs RAG with optional temporal filtering:
    1. Extract date range from question (or use explicit date_from/date_to)
    2. Embed the question
    3. Find similar chunks via pgvector (filtered by date if applicable)
    4. Find relevant entities
    5. Assemble context + history and generate answer with LLM

    With `client_request_id`, a repeated request returns the stored response (409 while
    the first one is still running) so a client retry never runs an action twice. The
    session is committed before the response is stored; if the action agent was started
    and anything fails, a retry gets a fixed "couldn't finish" answer instead of a rerun.
    Either way, the audit rows of tools that already ran are committed after a failure.
    """
    redis_client = request.app.state.redis
    key = None
    if body.client_request_id:
        key = f"query:req:{user_id}:{body.client_request_id}"
        if not await redis_client.set(
            key, _PROCESSING, nx=True, ex=REQUEST_MARKER_TTL_SECONDS
        ):
            stored = await redis_client.get(key)
            if isinstance(stored, bytes):
                stored = stored.decode()
            if stored and stored != _PROCESSING:
                return QueryResponse.model_validate_json(stored)
            raise HTTPException(status_code=409, detail="Still working on it")

    recorder = AuditRecorder(db)
    progress = _Progress()
    try:
        response = await _answer_query(redis_client, body, user_id, recorder, progress)
        if key is not None:
            # The turn and any pending action are saved before the answer can be replayed
            await db.commit()
    except BaseException:
        if progress.agent_started:
            # Tools may already have run: keep their audit rows (get_db rolls back), and a
            # retry gets "couldn't finish", never a rerun
            await _commit_executed_audit(db, recorder)
            if key is not None:
                await _store_unfinished(redis_client, key, body.question, progress.session_id)
        elif key is not None:
            # Nothing ran: let the client retry instead of a 10-minute 409.
            await redis_client.delete(key)
        raise
    if key is not None:
        await redis_client.set(key, response.model_dump_json(), ex=REQUEST_MARKER_TTL_SECONDS)
    return response


async def _commit_executed_audit(db: AsyncSession, recorder: AuditRecorder) -> None:
    """After a failure on the agent path: roll back, re-add the audit rows, commit."""
    snapshot = recorder.snapshot_audit()  # read before the rollback discards the rows
    if not snapshot:
        return
    try:
        await db.rollback()
        restore_audit(db, snapshot)
        await db.commit()
    except Exception:
        logger.exception("Could not save the audit rows of a failed request")
        with suppress(Exception):
            await db.rollback()


async def _store_unfinished(
    redis_client: aioredis.Redis, key: str, question: str, session_id: str | None
) -> None:
    response = QueryResponse(
        answer=_UNFINISHED[detect_language(question)],
        sources=[],
        session_id=session_id or "",
        date_filter=None,
    )
    try:
        await redis_client.set(key, response.model_dump_json(), ex=REQUEST_MARKER_TTL_SECONDS)
    except Exception:
        # The "processing" marker stays: retries get 409 until it expires, never a rerun
        logger.warning("Could not store the unfinished answer", exc_info=True)


async def _answer_query(
    redis_client: aioredis.Redis,
    body: QueryRequest,
    user_id: uuid.UUID,
    db: AsyncSession,
    progress: _Progress | None = None,
) -> QueryResponse:
    progress = progress or _Progress()
    # Resolve or create session
    if body.session_id:
        try:
            session_uuid = uuid.UUID(body.session_id)
        except ValueError:
            raise HTTPException(status_code=422, detail="session_id must be a UUID")
    else:
        session_uuid = uuid.uuid4()
    session_id = str(session_uuid)
    progress.session_id = session_id
    history = await _get_session_history(redis_client, session_id)
    if not history and body.session_id:
        # Redis context expired: resume follow-up context from the persisted session
        history = await _load_persisted_history(db, user_id, session_uuid)

    # --- Tool requests (Gmail, Calendar, Slack, ...) go to the action agent ---
    llm_service = get_llm_query_service()
    if might_need_tools(body.question, history):
        provider = None
        connected: list[str] = []
        use_agent = False
        try:
            provider = get_action_provider()
        except ActionProviderError:
            # Composio not configured on this server: memory answers only
            logger.info("Action provider not configured; using the memory path")
        if provider is not None:
            reachable: list[str] | None = None
            try:
                connected = await provider.connected_toolkits(str(user_id))
                reachable = connected
            except ActionProviderError:
                logger.warning("Action provider unreachable", exc_info=True)
            route = await route_request(llm_service, body.question, history, reachable)
            if route.kind == "notice":
                await _record_turn(
                    redis_client, db, user_id, session_id, history, body.question,
                    route.notice, {"actions": True},
                )
                return QueryResponse(
                    answer=route.notice, sources=[], session_id=session_id, date_filter=None
                )
            use_agent = route.kind == "agent"
        if use_agent:
            progress.agent_started = True
            outcome = await run_action_agent(
                db,
                user_id,
                body.question,
                history,
                session_id=session_uuid,
                source="chat",
                provider=provider,
                llm=llm_service,
                connected_toolkits=connected,
            )
            pending = outcome.pending_action
            extra: dict = {"actions": True}
            pending_out = None
            if pending is not None:
                extra["pending_action"] = {
                    "id": str(pending.id),
                    "summary": pending.summary,
                    "status": "pending",
                }
                pending_out = PendingActionOut(
                    id=pending.id,
                    summary=pending.summary,
                    status=pending.status,
                    expires_at=pending.expires_at,
                )
            await _record_turn(
                redis_client, db, user_id, session_id, history, body.question,
                outcome.answer, extra,
            )
            return QueryResponse(
                answer=outcome.answer,
                sources=[],
                session_id=session_id,
                date_filter=None,
                pending_action=pending_out,
            )

    # 1. Determine date filter: explicit params take priority, then NLP extraction
    date_range = None
    if body.date_from or body.date_to:
        # Either end may be open; naive values are treated as UTC
        date_range = DateRange(
            date_from=_as_utc(body.date_from),
            date_to=_as_utc(body.date_to),
        )
    else:
        date_range = extract_date_range(body.question)

    # 2. Retrieve memory (embed, chunk search, re-ranking, entities, summaries)
    memory = await retrieve_memory_context(
        db,
        user_id,
        body.question,
        top_k=body.top_k,
        date_range=date_range,
        embedding_service=get_embedding_service(),
    )

    if not memory.context:
        no_result_msg = no_results_message(body.question, date_range)
        # Save to history even for empty results
        await _record_turn(
            redis_client, db, user_id, session_id, history, body.question, no_result_msg
        )

        return QueryResponse(
            answer=no_result_msg,
            sources=[],
            session_id=session_id,
            date_filter=_format_date_filter(date_range),
        )

    context = memory.context
    sources = [SourceChunk(**src) for src in memory.sources]

    # 7. Generate answer via LLM (with conversation history)
    system_prompt = rag_system_prompt(date_range)

    messages = [LLMMessage(role="system", content=system_prompt)]

    # Add conversation history for multi-turn context
    for msg in history:
        messages.append(LLMMessage(role=msg["role"], content=msg["content"]))

    # Add current question with fresh RAG context
    user_message = f"Context from memory:\n\n{context}\n\n---\n\nQuestion: {body.question}"
    messages.append(LLMMessage(role="user", content=user_message))

    response = await llm_service.complete(messages, temperature=0.3)

    # Save to session history (store clean question, not the RAG-augmented one)
    # and persist to Postgres for permanent chat history
    await _record_turn(
        redis_client, db, user_id, session_id, history, body.question, response.content
    )

    return QueryResponse(
        answer=response.content,
        sources=sources,
        session_id=session_id,
        date_filter=_format_date_filter(date_range),
    )


async def _load_persisted_history(
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


async def _record_turn(
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
    await _save_session_history(redis_client, session_id, history)
    await _persist_chat_session(db, user_id, session_id, turn)


async def _persist_chat_session(
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


def _format_date_filter(date_range: DateRange | None) -> dict | None:
    """Format date range for API response."""
    if date_range is None:
        return None
    return {
        "from": date_range.date_from.isoformat() if date_range.date_from else None,
        "to": date_range.date_to.isoformat() if date_range.date_to else None,
    }


def _as_utc(value: datetime | None) -> datetime | None:
    """Make an explicit filter bound timezone-aware (naive values are UTC)."""
    if value is None or value.tzinfo is not None:
        return value
    return value.replace(tzinfo=timezone.utc)


def _describe_period(date_range: DateRange) -> str:
    """Period for the RAG prompt; open ends are described in words."""
    if date_range.date_from and date_range.date_to:
        return (
            f"{date_range.date_from.strftime('%d/%m/%Y')} - "
            f"{date_range.date_to.strftime('%d/%m/%Y')}"
        )
    if date_range.date_from:
        return f"from {date_range.date_from.strftime('%d/%m/%Y')} onwards"
    return f"until {date_range.date_to.strftime('%d/%m/%Y')}"


def rag_system_prompt(date_range: DateRange | None) -> str:
    """System prompt for memory answers, written in the question's language."""
    prompt = (
        "You are a personal assistant. The user asks about their own memory: "
        "past conversations, ideas, tasks and people they mentioned. "
        "Answer ONLY from the provided context. The context includes:\n"
        "- 'Relevant conversation summaries' for a high-level overview\n"
        "- 'Structured knowledge' (entities: people, tasks, ideas, events)\n"
        "- Excerpts of real transcripts for specific details\n\n"
        "Use the summaries for general questions ('what happened yesterday?') and the "
        "excerpts for specific ones ('what exactly did Marco say?'). Transcripts may be "
        "in another language than the question: quote them as they are when useful. "
        "If the context is not enough, say so clearly. For follow-up questions, use the "
        "previous conversation to understand what the user refers to. "
        "Always answer in the same language as the user's question."
    )
    if date_range:
        prompt += f"\n\nNote: results are filtered to the period {_describe_period(date_range)}."
    return prompt


_NO_RESULTS = {
    "en": "I don't have anything in your memory to answer this yet.",
    "it": "Non ho ancora informazioni nella memoria per rispondere a questa domanda.",
}
_NO_RESULTS_IN_PERIOD = {
    "en": (
        "I couldn't find anything in your memory for that period. "
        "Try rephrasing the question or widening the period."
    ),
    "it": (
        "Non ho trovato informazioni nella memoria per il periodo indicato. "
        "Prova a riformulare la domanda o a estendere il periodo."
    ),
}


def no_results_message(question: str, date_range: DateRange | None) -> str:
    """Reply when memory has nothing relevant, in the question's language."""
    messages = _NO_RESULTS_IN_PERIOD if date_range else _NO_RESULTS
    return messages[detect_language(question)]
