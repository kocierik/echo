"""Daily digest generation.

Generates a structured summary of the user's day:
- People mentioned
- Tasks extracted
- Ideas/decisions
- Events
- Overall narrative summary

Can be triggered on a schedule (cron-style) or manually via API.
"""

import asyncio
import logging
import uuid
from datetime import date, datetime, time, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import async_session
from app.core.timezone import local_day_bounds, user_zone
from app.models.conversation import Conversation
from app.models.digest import Digest
from app.models.entity import Entity
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_analysis_service
from app.services.temporal import conversation_overlaps
from app.workers.lifecycle import sleep_or_shutdown
from app.workers.retry import retry_with_backoff

logger = logging.getLogger(__name__)


def next_digest_run(now: datetime) -> tuple[datetime, date]:
    """Next run time and the local day it summarizes.

    Runs at settings.digest_local_hour in the user's timezone and summarizes
    the day that has just ended (the previous local day).
    """
    zone = user_zone()
    local_now = now.astimezone(zone)
    run_day = local_now.date()
    if local_now.time() >= time(settings.digest_local_hour):
        run_day += timedelta(days=1)
    run_at = datetime.combine(run_day, time(settings.digest_local_hour), tzinfo=zone)
    return run_at, run_day - timedelta(days=1)


async def generate_digest_for_date(
    user_id: uuid.UUID, target_date: date, db: AsyncSession
) -> Digest | None:
    """Generate a daily digest for a specific user and date.

    Args:
        user_id: User to generate digest for.
        target_date: The date to summarize.
        db: Database session.

    Returns:
        Digest object if content was found, None if the day was empty.
    """
    # Check if digest already exists
    existing = await db.execute(
        select(Digest)
        .where(Digest.user_id == user_id)
        .where(Digest.digest_date == target_date)
    )
    if existing.scalar_one_or_none() is not None:
        logger.info(f"[Digest] Digest already exists for {user_id} on {target_date}")
        return None

    # Get all conversations for this user on target_date
    day_start, day_end = local_day_bounds(target_date)

    conversations_query = (
        select(Conversation)
        .where(Conversation.user_id == user_id)
        .where(*conversation_overlaps(day_start, day_end))
        .order_by(Conversation.started_at)
    )
    result = await db.execute(conversations_query)
    conversations = result.scalars().all()

    if not conversations:
        logger.info(f"[Digest] No conversations for {user_id} on {target_date}")
        return None

    # Gather all transcription texts for the day
    conv_ids = [c.id for c in conversations]
    transcriptions_query = (
        select(Transcription.text)
        .join(Segment, Segment.id == Transcription.segment_id)
        .where(Segment.conversation_id.in_(conv_ids))
        # Only what was said that day: a conversation may cross midnight
        .where(Segment.recorded_at >= day_start)
        .where(Segment.recorded_at < day_end)
        .order_by(Segment.recorded_at)
    )
    result = await db.execute(transcriptions_query)
    texts = [row[0] for row in result.all()]

    if not texts:
        return None

    full_text = "\n\n".join(texts)

    # Gather conversation summaries (more compact than raw text)
    conv_summaries = [
        f"- {c.title or 'Conversazione'}: {c.summary}"
        for c in conversations
        if c.summary
    ]

    # Gather entities for the day
    entities_query = (
        select(Entity)
        .where(Entity.user_id == user_id)
        .where(Entity.conversation_id.in_(conv_ids))
    )
    result = await db.execute(entities_query)
    entities = result.scalars().all()

    # Categorize entities
    people = [e.name for e in entities if e.entity_type == "person"]
    tasks = [
        {"name": e.name, "content": e.content, **e.metadata_}
        for e in entities if e.entity_type == "task"
    ]
    ideas = [
        {"name": e.name, "content": e.content}
        for e in entities if e.entity_type == "idea"
    ]
    events = [
        {"name": e.name, "content": e.content, **e.metadata_}
        for e in entities if e.entity_type == "event"
    ]

    # Generate narrative summary via LLM
    llm_service = get_llm_analysis_service()

    # Use conversation summaries if available (more concise), fall back to raw text
    if conv_summaries:
        input_text = (
            "Riassunti delle conversazioni:\n" + "\n".join(conv_summaries) +
            f"\n\nTrascrizioni (per dettagli):\n\n{full_text[:3000]}"
        )
    else:
        # Truncate if too long
        max_chars = 5000
        input_text = full_text[:max_chars] if len(full_text) > max_chars else full_text

    messages = [
        LLMMessage(
            role="system",
            content=(
                "Sei un assistente personale. Genera un riassunto della giornata dell'utente "
                "basandoti sulle trascrizioni delle sue conversazioni.\n\n"
                "Il riassunto deve essere:\n"
                "- Conciso (3-5 frasi)\n"
                "- In prima persona\n"
                "- Focalizzato su decisioni, informazioni chiave, e azioni\n"
                "- In italiano\n\n"
                "Rispondi in JSON:\n"
                '{"summary": "riassunto narrativo della giornata"}'
            ),
        ),
        LLMMessage(
            role="user",
            content=(
                f"Data: {target_date.strftime('%d/%m/%Y')}\n"
                f"Conversazioni: {len(conversations)}\n"
                f"Persone menzionate: {', '.join(set(people)) or 'nessuna'}\n\n"
                f"{input_text}"
            ),
        ),
    ]

    result = await retry_with_backoff(
        llm_service.complete_json,
        messages,
        operation_name=f"Digest {target_date}",
    )
    summary = result.get("summary", "Nessun riassunto disponibile.")

    # Create and save digest
    digest = Digest(
        user_id=user_id,
        digest_date=target_date,
        summary=summary,
        people=list(set(people)),
        tasks=tasks,
        ideas=ideas,
        events=events,
        conversation_count=len(conversations),
    )
    db.add(digest)
    await db.commit()

    logger.info(
        f"[Digest] Generated for {user_id} on {target_date}: "
        f"{len(conversations)} conversations, {len(entities)} entities"
    )
    return digest


async def run_digest_loop(shutdown_event: asyncio.Event | None = None):
    """Periodic loop: at settings.digest_local_hour, digest the day that just ended."""
    logger.info(
        f"[Digest] Loop started — generating at {settings.digest_local_hour}:00 "
        f"{settings.user_timezone} for the previous day"
    )

    while True:
        if shutdown_event and shutdown_event.is_set():
            break

        now = datetime.now(timezone.utc)
        next_run, target_day = next_digest_run(now)

        wait_seconds = (next_run - now).total_seconds()
        logger.info(f"[Digest] Next run in {wait_seconds / 3600:.1f}h ({next_run.isoformat()})")

        if await sleep_or_shutdown(wait_seconds, shutdown_event):
            return

        await generate_digests_for_all_users(target_day)


async def generate_digests_for_all_users(target_date: date):
    """Generate digests for all users that had conversations on target_date."""
    async with async_session() as db:
        # Find all users with conversations on that date
        day_start, day_end = local_day_bounds(target_date)

        users_query = (
            select(Conversation.user_id)
            .where(*conversation_overlaps(day_start, day_end))
            .distinct()
        )
        result = await db.execute(users_query)
        user_ids = [row[0] for row in result.all()]

    for user_id in user_ids:
        try:
            async with async_session() as db:
                await generate_digest_for_date(user_id, target_date, db)
        except Exception as e:
            logger.error(f"[Digest] Failed for user {user_id} on {target_date}: {e}")
