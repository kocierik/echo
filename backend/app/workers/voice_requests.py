"""Voice requests worker: answers "Echo, ..." commands into the "Voice requests" chat.

The STT worker pushes the id of each segment where `find_wake` hits onto `queue:voice`.
Every POLL_INTERVAL_S this loop takes the queued ids (oldest first): items whose command
is still being spoken or transcribed go back to the queue; ready ones are confirmed with
the cheap LLM, routed by the same intent check as chat (memory, a fixed "not connected"
or "unreachable" answer, or the action agent) and appended, question and answer with ISO
timestamps, to the user's voice session.

If answering fails once the request is confirmed, the transaction is rolled back, the
audit rows of tools that already ran are written again and the user gets a short
localized "couldn't complete that" reply, so an action never happens silently.
"""

import asyncio
import logging
import uuid
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime, timezone

from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.agent import run_action_agent
from app.actions.audit import AuditRecorder, restore_audit
from app.actions.availability import route_request
from app.actions.composio_provider import get_action_provider
from app.actions.provider import ActionProviderError
from app.actions.voice import (
    collect_command,
    find_wake,
    get_or_create_voice_session,
    is_assistant_request,
    strip_speaker_tag,
)
from app.core.database import async_session
from app.models.segment import Segment
from app.routers.query import no_results_message, rag_system_prompt
from app.services.embedding_openai import get_embedding_service
from app.services.language import detect_language
from app.services.llm_base import LLMMessage, LLMService
from app.services.llm_openai import get_llm_analysis_service, get_llm_query_service
from app.services.memory_retrieval import retrieve_memory_context
from app.services.temporal import extract_date_range
from app.workers.lifecycle import sleep_or_shutdown

logger = logging.getLogger(__name__)

VOICE_QUEUE = "queue:voice"
POLL_INTERVAL_S = 2
# A segment answered once is never answered again (re-transcription, duplicate pushes).
DONE_KEY = "voice:done:{segment_id}"
DONE_TTL_S = 7 * 24 * 3600
# Voice-session messages passed to the agent/LLM as conversation history.
HISTORY_MESSAGES = 10


FAILURE_TEXTS = {
    "en": {
        "failed": "Sorry, I couldn't complete that request. Please try again.",
        "failed_partial": (
            "Sorry, I couldn't complete that request. Some steps may already have run: "
            "check the action log in the app."
        ),
    },
    "it": {
        "failed": "Mi dispiace, non sono riuscito a completare la richiesta. Riprova.",
        "failed_partial": (
            "Mi dispiace, non sono riuscito a completare la richiesta. Alcuni passaggi "
            "potrebbero essere già stati eseguiti: controlla il registro azioni nell'app."
        ),
    },
}

@dataclass
class _Claim:
    claimed: bool = False
    # Set once the request is confirmed: a failure from then on is reported to the user.
    user_id: uuid.UUID | None = None
    command: str | None = None


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _parse_segment_id(raw) -> uuid.UUID | None:
    try:
        value = raw.decode() if isinstance(raw, bytes) else str(raw)
        return uuid.UUID(value)
    except (UnicodeDecodeError, ValueError):
        return None


def _heard_text(wake_text: str, command: str) -> str:
    """The whole utterance (what came before the name, the name, the command)."""
    command_start = find_wake(wake_text)
    lead = wake_text[:command_start] if command_start is not None else ""
    return f"{strip_speaker_tag(lead).strip()} {command}".strip()


async def _memory_answer(
    db: AsyncSession,
    user_id: uuid.UUID,
    command: str,
    history: list[dict],
    llm: LLMService,
) -> str:
    """RAG answer from the user's memory (no connected app to act on)."""
    date_range = extract_date_range(command)
    memory = await retrieve_memory_context(
        db,
        user_id,
        command,
        date_range=date_range,
        embedding_service=get_embedding_service(),
    )
    if not memory.context:
        return no_results_message(command, date_range)
    messages = [LLMMessage(role="system", content=rag_system_prompt(date_range))]
    messages.extend(LLMMessage(role=m["role"], content=m["content"]) for m in history)
    messages.append(
        LLMMessage(
            role="user",
            content=f"Context from memory:\n\n{memory.context}\n\n---\n\nQuestion: {command}",
        )
    )
    response = await llm.complete(messages, temperature=0.3)
    return response.content


async def _answer(
    db: AsyncSession,
    user_id: uuid.UUID,
    command: str,
    history: list[dict],
    session_id: uuid.UUID,
) -> tuple[str, dict]:
    """The answer and the extra keys of the assistant message."""
    provider = None
    connected: list[str] = []
    llm = get_llm_query_service()
    try:
        provider = get_action_provider()
    except ActionProviderError:
        logger.info("[Voice] Action provider not configured; answering from memory")
    if provider is None:
        return await _memory_answer(db, user_id, command, history, llm), {}
    # Every confirmed voice request goes through the same intent check as chat
    reachable: list[str] | None = None
    try:
        connected = await provider.connected_toolkits(str(user_id))
        reachable = connected
    except ActionProviderError:
        logger.warning("[Voice] Action provider unreachable", exc_info=True)
    route = await route_request(llm, command, history, reachable)
    if route.kind == "notice":
        return route.notice, {"actions": True}
    if route.kind == "memory":
        return await _memory_answer(db, user_id, command, history, llm), {}

    outcome = await run_action_agent(
        db,
        user_id,
        command,
        history,
        session_id=session_id,
        source="voice",
        provider=provider,
        llm=llm,
        connected_toolkits=connected,
    )
    extra: dict = {"actions": True}
    if outcome.pending_action is not None:
        extra["pending_action"] = {
            "id": str(outcome.pending_action.id),
            "summary": outcome.pending_action.summary,
            "status": "pending",
        }
    return outcome.answer, extra


async def _process(
    db: AsyncSession, redis_client, segment_id: uuid.UUID, claim: _Claim
) -> bool:
    segment = await db.get(Segment, segment_id)
    if segment is None or segment.transcription is None:
        logger.warning(f"[Voice] Segment {segment_id} not found or not transcribed")
        return True

    command = await collect_command(db, segment, _utcnow())
    if command is None:
        return False
    if not command:
        logger.info(f"[Voice] Segment {segment_id}: Echo addressed without a command")
        return True

    claim.claimed = bool(
        await redis_client.set(
            DONE_KEY.format(segment_id=segment_id), "1", nx=True, ex=DONE_TTL_S
        )
    )
    if not claim.claimed:
        logger.info(f"[Voice] Segment {segment_id} already handled")
        return True

    heard = _heard_text(segment.transcription.text or "", command)
    if not await is_assistant_request(get_llm_analysis_service(), heard):
        logger.info(f"[Voice] Segment {segment_id}: not a request to Echo")
        return True
    claim.user_id = segment.user_id
    claim.command = command

    voice_session = await get_or_create_voice_session(db, segment.user_id)
    history = [
        {"role": m["role"], "content": m["content"]}
        for m in (voice_session.messages or [])[-HISTORY_MESSAGES:]
        if m.get("role") in ("user", "assistant") and isinstance(m.get("content"), str)
    ]
    asked_at = _utcnow().isoformat()
    answer, extra = await _answer(db, segment.user_id, command, history, voice_session.id)
    _append_turn(voice_session, command, asked_at, answer, extra)
    await db.commit()
    logger.info(f"[Voice] Answered request from segment {segment_id}")
    return True


def _append_turn(voice_session, command: str, asked_at: str, answer: str, extra: dict):
    answered_at = _utcnow()
    # Reassign (not mutate) so SQLAlchemy detects the JSONB change
    voice_session.messages = [
        *(voice_session.messages or []),
        {"role": "user", "content": command, "timestamp": asked_at},
        {
            "role": "assistant",
            "content": answer,
            "timestamp": answered_at.isoformat(),
            **extra,
        },
    ]
    voice_session.updated_at = answered_at


async def _report_failure(db: AsyncSession, claim: _Claim, audit: list[dict]) -> None:
    """After a rollback: restore executed tools' audit rows and tell the user it failed."""
    restore_audit(db, audit)
    texts = FAILURE_TEXTS[detect_language(claim.command)]
    reply = texts["failed_partial"] if audit else texts["failed"]
    voice_session = await get_or_create_voice_session(db, claim.user_id)
    _append_turn(voice_session, claim.command, _utcnow().isoformat(), reply, {})
    await db.commit()


async def handle_voice_item(redis_client, raw) -> bool:
    """Handle one queued segment id. False = not ready yet (requeue); True = done/dropped.

    Each request runs in its own DB session and commits it; errors are logged and the
    item is dropped. If the worker is cancelled before the request was claimed, the item
    goes back to the queue.
    """
    segment_id = _parse_segment_id(raw)
    if segment_id is None:
        logger.warning(f"[Voice] Dropping invalid queue item {raw!r}")
        return True

    claim = _Claim()
    async with async_session() as session:
        db = AuditRecorder(session)
        try:
            return await _process(db, redis_client, segment_id, claim)
        except asyncio.CancelledError:
            if not claim.claimed:
                await redis_client.lpush(VOICE_QUEUE, raw)
            raise
        except Exception:
            logger.exception(f"[Voice] Request from segment {segment_id} failed")
            audit = db.snapshot_audit()
            with suppress(Exception):
                await session.rollback()
            if claim.command is not None:
                try:
                    await _report_failure(session, claim, audit)
                except Exception:
                    logger.exception(
                        f"[Voice] Could not record the failure of segment {segment_id}"
                    )
                    with suppress(Exception):
                        await session.rollback()
            return True


async def process_voice_queue(redis_client, shutdown_event: asyncio.Event) -> None:
    """Poll `queue:voice` every POLL_INTERVAL_S until shutdown."""
    while not shutdown_event.is_set():
        try:
            queued = await redis_client.llen(VOICE_QUEUE)
            for _ in range(queued):
                if shutdown_event.is_set():
                    break
                raw = await redis_client.rpop(VOICE_QUEUE)  # producers lpush: oldest first
                if raw is None:
                    break
                if not await handle_voice_item(redis_client, raw):
                    # Back to the tail: older items keep their turn
                    await redis_client.lpush(VOICE_QUEUE, raw)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Voice] Queue poll failed")
        if await sleep_or_shutdown(POLL_INTERVAL_S, shutdown_event):
            break
