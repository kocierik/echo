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

from sqlalchemy import func, select

from app.core.config import settings
from app.core.database import async_session
from app.models.conversation import Conversation
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.analysis_pipeline import generate_conversation_summary
from app.services.llm_openai import get_llm_analysis_service
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
                title, summary = await retry_with_backoff(
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

            conversation.title = title
            conversation.summary = summary
            summarized += 1

        await db.commit()

    return summarized


async def run_summary_loop(shutdown_event: asyncio.Event | None = None):
    """Periodically summarize conversations that have been closed."""
    logger.info(
        "[Summaries] Started: summarizing conversations quiet for %ss (checking every %ss)",
        settings.silence_timeout_ms // 1000,
        settings.summary_check_interval_s,
    )
    while not (shutdown_event and shutdown_event.is_set()):
        try:
            count = await summarize_closed_conversations()
            if count:
                logger.info("[Summaries] Summarized %s conversations", count)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Summaries] Error during summary generation")

        if await sleep_or_shutdown(settings.summary_check_interval_s, shutdown_event):
            return
