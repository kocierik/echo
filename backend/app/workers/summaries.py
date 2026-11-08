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
from sqlalchemy import func, select, true

from app.core.config import settings
from app.core.database import async_session
from app.models.conversation import Conversation
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.analysis_pipeline import generate_conversation_summary
from app.services.fact_suggestions import suggest_facts
from app.services.llm_openai import get_llm_analysis_service
from app.services.retranscription import (
    conversations_to_retranscribe,
    mark_reanalysis,
    retranscribe,
)
from app.services.stt_openai import get_stt_service
from app.services.usage import usage_owner
from app.workers.lifecycle import sleep_or_shutdown
from app.workers.retry import RetryExhaustedError, retry_with_backoff

logger = logging.getLogger(__name__)


def _build_closed_conversations_query(now: datetime):
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    cutoff = now - timedelta(milliseconds=settings.silence_timeout_ms)
    return (
        select(Conversation)
        .where(Conversation.summary.is_(None))
        .where(Conversation.analysis_status == "completed")
        # Transcribed again whole first: its summary is written from the better text
        .where(
            Conversation.retranscribed_at.is_not(None)
            if settings.conversation_retranscription
            else true()
        )
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
                result = await retry_with_backoff(
                    generate_conversation_summary,
                    llm,
                    full_text,
                    operation_name=f"Summary conversation {conversation.id}",
                )
            except RetryExhaustedError as exc:
                # Left as None: retried on the next run
                logger.error(
                    "[Summaries] Failed for conversation %s: %s",
                    conversation.id,
                    exc.last_error,
                )
                continue

            conversation.title = result.title
            conversation.summary = result.summary
            conversation.emoji = result.emoji
            summarized += 1
            # What the user said about themselves: suggestions for About you. A failure
            # here never costs the summary
            try:
                async with db.begin_nested():
                    await suggest_facts(db, llm, conversation)
            except Exception:
                logger.warning("[Summaries] No fact suggestions for %s", conversation.id,
                               exc_info=True)

        await db.commit()

    return summarized


async def retranscribe_closed_conversations(
    redis_client,
    *,
    now: datetime | None = None,
    session_factory=async_session,
    stt=None,
) -> int:
    """Transcribe closed conversations again whole (services/retranscription.py);
    the ones whose text changed are analysed again. Returns how many."""
    effective_now = now or datetime.now(timezone.utc)
    stt = stt or get_stt_service()
    changed: list = []
    async with session_factory() as db:
        for conversation in await conversations_to_retranscribe(
            db, effective_now, settings.summary_batch_size
        ):
            usage_owner.set(conversation.user_id)
            conversation.retranscribed_at = effective_now  # once, whatever happens
            try:
                async with db.begin_nested():
                    if await retranscribe(db, conversation, stt):
                        conversation.analysis_status = "reprocessing"
                        changed.append(conversation.id)
            except Exception:
                logger.warning("[Summaries] Not transcribed again: %s", conversation.id,
                               exc_info=True)
        await db.commit()
    for conversation_id in changed:
        await mark_reanalysis(redis_client, conversation_id, effective_now)
    return len(changed)


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
            if settings.conversation_retranscription:
                again = await retranscribe_closed_conversations(redis_client)
                if again:
                    logger.info("[Summaries] Transcribed again: %s conversations", again)
            count = await summarize_closed_conversations()
            if count:
                logger.info("[Summaries] Summarized %s conversations", count)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Summaries] Error during summary generation")

        if await sleep_or_shutdown(settings.summary_check_interval_s, shutdown_event):
            return
