"""Generate titles and summaries for closed conversations.

The analysis pipeline keeps each segment's raw transcript as the canonical
text and never summarizes while a conversation is still growing. Once a
conversation has been quiet for longer than the silence timeout it is
"closed": this loop then writes its title and summary, which the RAG prompt
and the daily digest use as high-level context.

Conversations too short to summarize get an empty summary ("") so they are
not picked up again; a transcript correction resets title/summary to None
and the reanalysis (or this loop) fills them again.
"""

import asyncio
import logging
from datetime import datetime, timedelta, timezone

import redis.asyncio as aioredis
from sqlalchemy import func, select

from app.core.config import settings
from app.core.database import async_session
from app.models.conversation import Conversation
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.conversation_close import write_summary
from app.services.llm_openai import get_llm_analysis_service
from app.services.retranscription import (
    conversations_to_retranscribe,
    mark_reanalysis,
    retranscribe,
)
from app.services.stt_openai import get_stt_service
from app.services.usage import usage_owner
from app.workers.lifecycle import sleep_or_shutdown
from app.workers.retry import RetryExhaustedError

logger = logging.getLogger(__name__)


def _build_closed_conversations_query(now: datetime):
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    cutoff = now - timedelta(milliseconds=settings.silence_timeout_ms)
    return (
        select(Conversation)
        .where(Conversation.summary.is_(None))
        .where(Conversation.analysis_status == "completed")
        # Read whole first (close_conversations): its analysis writes the summary; this
        # loop is for what that left without one
        .where(Conversation.retranscribed_at.is_not(None))
        .where(func.coalesce(Conversation.ended_at, Conversation.started_at) < cutoff)
        .order_by(Conversation.started_at.asc())
        .limit(settings.summary_batch_size)
        .with_for_update(skip_locked=True)
    )


async def summarize_closed_conversations(
    *,
    now: datetime | None = None,
    session_factory=async_session,
    llm_service=None,
) -> int:
    """Summarize one batch of closed conversations. Returns how many got a summary."""
    effective_now = now or datetime.now(timezone.utc)
    llm = llm_service or get_llm_analysis_service()
    summarized = 0

    async with session_factory() as db:
        result = await db.execute(_build_closed_conversations_query(effective_now))
        conversations = result.scalars().all()

        for conversation in conversations:
            usage_owner.set(conversation.user_id)
            texts_result = await db.execute(
                select(Transcription.text)
                .join(Segment, Segment.id == Transcription.segment_id)
                .where(Segment.conversation_id == conversation.id)
                .order_by(Segment.recorded_at)
            )
            full_text = " ".join(
                text.strip() for (text,) in texts_result.all() if text and text.strip()
            )

            if len(full_text.split()) <= settings.summary_min_words:
                conversation.summary = ""  # nothing to summarize: don't pick it again
                continue

            try:
                await write_summary(db, llm, conversation, full_text)
            except RetryExhaustedError as exc:
                # Left as None: retried on the next run
                logger.error(
                    "[Summaries] Failed for conversation %s: %s",
                    conversation.id,
                    exc.last_error,
                )
                continue
            summarized += 1

        await db.commit()

    return summarized


async def close_conversations(
    redis_client,
    *,
    now: datetime | None = None,
    session_factory=async_session,
    stt=None,
) -> int:
    """Closed conversations read whole, once each: transcribed again
    (services/retranscription.py, when turned on), then queued for their analysis
    (services/conversation_reanalysis.py): entities, chunks, summary, topics and facts.
    A segment alone gets none of them any more. Returns how many were queued."""
    effective_now = now or datetime.now(timezone.utc)
    stt = (stt or get_stt_service()) if settings.conversation_retranscription else None
    closed: list = []
    async with session_factory() as db:
        for conversation in await conversations_to_retranscribe(
            db, effective_now, settings.summary_batch_size
        ):
            usage_owner.set(conversation.user_id)
            conversation.retranscribed_at = effective_now  # once, whatever happens
            if stt is not None:
                try:
                    async with db.begin_nested():
                        await retranscribe(db, conversation, stt)
                except Exception:
                    logger.warning("[Summaries] Not transcribed again: %s", conversation.id,
                                   exc_info=True)
            conversation.analysis_status = "reprocessing"
            closed.append(conversation.id)
        await db.commit()
    for conversation_id in closed:
        await mark_reanalysis(redis_client, conversation_id, effective_now)
    return len(closed)


async def run_summary_loop(shutdown_event: asyncio.Event | None = None):
    """Periodically summarize conversations that have been closed."""
    logger.info(
        "[Summaries] Started: summarizing conversations quiet for %ss (checking every %ss)",
        settings.silence_timeout_ms // 1000,
        settings.summary_check_interval_s,
    )
    redis_client = aioredis.from_url(settings.redis_url)
    while not (shutdown_event and shutdown_event.is_set()):
        try:
            closed = await close_conversations(redis_client)
            if closed:
                logger.info("[Summaries] Closed and queued for analysis: %s conversations",
                            closed)
            count = await summarize_closed_conversations()
            if count:
                logger.info("[Summaries] Summarized %s conversations", count)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Summaries] Error during summary generation")

        if await sleep_or_shutdown(settings.summary_check_interval_s, shutdown_event):
            return
