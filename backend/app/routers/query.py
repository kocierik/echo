"""Query API: natural language search over personal memory with RAG."""

import asyncio
import json
import logging
import re
import uuid
from collections.abc import Awaitable, Callable
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime

import redis.asyncio as aioredis
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.actions.agent import run_action_agent
from app.actions.audit import AuditRecorder, restore_audit
from app.actions.availability import route_request
from app.actions.composio_provider import get_action_provider
from app.actions.phone_provider import with_phone_apps
from app.actions.provider import ActionProviderError
from app.core.auth import get_current_user_id
from app.core.database import get_db, get_session_factory
from app.core.rate_limit import limiter
from app.services.chat_history import (
    get_session_history,
    load_persisted_history,
    record_turn,
)
from app.services.embedding_openai import get_embedding_service
from app.services.language import detect_language
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_intent_service, get_llm_query_service
from app.services.memory_answers import (
    as_utc,
    format_date_filter,
    no_results_message,
    rag_system_prompt,
)
from app.services.memory_retrieval import retrieve_memory_context
from app.services.temporal import DateRange, extract_date_range

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/query", tags=["query"])

# Session TTL: 30 minutes of inactivity
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


# Receives each piece of a streamed answer
TokenCallback = Callable[[str], Awaitable[None]]


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
    # The conversation's title and start, to label the source
    title: str | None = None
    started_at: datetime | None = None

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
    r"inbox|ricordami|ricordarmi|remind|promemoria)",
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
    key, stored = await _claim_request(redis_client, user_id, body)
    if stored is not None:
        return stored
    return await _answer_and_store(redis_client, key, body, user_id, db)


@router.post("/stream")
@limiter.limit("20/minute")
async def query_memory_stream(
    request: Request,
    body: QueryRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    session_factory: async_sessionmaker = Depends(get_session_factory),
):
    """`POST /api/query` as Server-Sent Events, so the answer shows while it is written.

    Events: `token` ({"text"}) for each piece of a memory answer, then `done` with the
    full QueryResponse, or `error` ({"status", "detail"}). Answers from the action agent
    and fixed notices arrive whole in `done`. Retries with the same `client_request_id`
    behave as in `POST /api/query` (409 before the stream starts). If the client goes
    away, the answer is still completed and stored for its retry.
    """
    redis_client = request.app.state.redis
    key, stored = await _claim_request(redis_client, user_id, body)
    queue: asyncio.Queue[tuple[str, str]] = asyncio.Queue()

    async def on_token(piece: str) -> None:
        await queue.put(("token", json.dumps({"text": piece})))

    async def answer() -> None:
        async with session_factory() as db:
            try:
                response = await _answer_and_store(
                    redis_client, key, body, user_id, db, on_token
                )
                await db.commit()
                await queue.put(("done", response.model_dump_json()))
            except HTTPException as exc:
                await db.rollback()
                error = {"status": exc.status_code, "detail": exc.detail}
                await queue.put(("error", json.dumps(error)))
            except Exception:
                logger.exception("Streaming query failed")
                await db.rollback()
                error = {"status": 500, "detail": "Echo could not answer. Try again."}
                await queue.put(("error", json.dumps(error)))

    async def events():
        if stored is not None:
            yield _sse("done", stored.model_dump_json())
            return
        # Not tied to this generator: a client that disconnects does not cancel it
        task = asyncio.create_task(answer())
        _RUNNING.add(task)
        task.add_done_callback(_RUNNING.discard)
        while True:
            kind, data = await queue.get()
            yield _sse(kind, data)
            if kind != "token":
                return

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# Streaming answers still running (a reference keeps them from being collected)
_RUNNING: set[asyncio.Task] = set()


def _sse(event: str, data: str) -> str:
    return f"event: {event}\ndata: {data}\n\n"


async def _claim_request(
    redis_client: aioredis.Redis, user_id: uuid.UUID, body: QueryRequest
) -> tuple[str | None, QueryResponse | None]:
    """Mark a request with a client_request_id as running.

    Returns its marker key and, when it already finished, the stored answer to replay;
    raises 409 while the first attempt is still running.
    """
    if not body.client_request_id:
        return None, None
    key = f"query:req:{user_id}:{body.client_request_id}"
    if await redis_client.set(key, _PROCESSING, nx=True, ex=REQUEST_MARKER_TTL_SECONDS):
        return key, None
    stored = await redis_client.get(key)
    if isinstance(stored, bytes):
        stored = stored.decode()
    if stored and stored != _PROCESSING:
        return key, QueryResponse.model_validate_json(stored)
    raise HTTPException(status_code=409, detail="Still working on it")


async def _answer_and_store(
    redis_client: aioredis.Redis,
    key: str | None,
    body: QueryRequest,
    user_id: uuid.UUID,
    db: AsyncSession,
    on_token: TokenCallback | None = None,
) -> QueryResponse:
    """Answer, then store the answer under the request's marker for its retries."""
    recorder = AuditRecorder(db)
    progress = _Progress()
    try:
        response = await _answer_query(
            redis_client, body, user_id, recorder, progress, on_token
        )
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
    on_token: TokenCallback | None = None,
) -> QueryResponse:
    """Answer one question. With `on_token`, a memory answer is passed on as it is written."""
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
    history = await get_session_history(redis_client, session_id)
    if not history and body.session_id:
        # Redis context expired: resume follow-up context from the persisted session
        history = await load_persisted_history(db, user_id, session_uuid)

    # --- Tool requests (Gmail, Calendar, Slack, ...) go to the action agent ---
    llm_service = get_llm_query_service()
    if might_need_tools(body.question, history):
        provider = None
        connected: list[str] = []
        use_agent = False
        try:
            provider = get_action_provider()
        except ActionProviderError:
            # Composio not configured on this server: only the iPhone's apps, if any
            logger.info("Action provider not configured")
        provider = await with_phone_apps(provider, redis_client, user_id)
        if provider is not None:
            reachable: list[str] | None = None
            try:
                connected = await provider.connected_toolkits(str(user_id))
                reachable = connected
            except ActionProviderError:
                logger.warning("Action provider unreachable", exc_info=True)
            route = await route_request(
                get_llm_intent_service(), body.question, history, reachable
            )
            if route.kind == "notice":
                await record_turn(
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
                connected_toolkits=route.apps or connected,
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
            await record_turn(
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
            date_from=as_utc(body.date_from),
            date_to=as_utc(body.date_to),
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
        await record_turn(
            redis_client, db, user_id, session_id, history, body.question, no_result_msg
        )

        return QueryResponse(
            answer=no_result_msg,
            sources=[],
            session_id=session_id,
            date_filter=format_date_filter(date_range),
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

    if on_token is None:
        answer = (await llm_service.complete(messages, temperature=0.3)).content
    else:
        pieces: list[str] = []
        async for piece in llm_service.stream(messages, temperature=0.3):
            pieces.append(piece)
            await on_token(piece)
        answer = "".join(pieces)

    # Save to session history (store clean question, not the RAG-augmented one)
    # and persist to Postgres for permanent chat history
    await record_turn(redis_client, db, user_id, session_id, history, body.question, answer)

    return QueryResponse(
        answer=answer,
        sources=sources,
        session_id=session_id,
        date_filter=format_date_filter(date_range),
    )


