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

from app.core.database import async_session
from app.models.conversation import Conversation
from app.models.digest import Digest
from app.models.entity import Entity
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_analysis_service
from app.workers.retry import retry_with_backoff

logger = logging.getLogger(__name__)

# Run digest generation at this hour (UTC)
DIGEST_HOUR_UTC = 21  # 21:00 UTC = 23:00 CET


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
    day_start = datetime.combine(target_date, time.min, tzinfo=timezone.utc)
    day_end = datetime.combine(target_date, time.max, tzinfo=timezone.utc)

    conversations_query = (
        select(Conversation)
        .where(Conversation.user_id == user_id)
        .where(Conversation.started_at >= day_start)
        .where(Conversation.started_at <= day_end)
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
    """Periodic loop that generates digests at DIGEST_HOUR_UTC.

    Generates yesterday's digest for all users that have conversations.
    """
    logger.info(f"[Digest] Loop started — generating at {DIGEST_HOUR_UTC}:00 UTC daily")

    while True:
        if shutdown_event and shutdown_event.is_set():
            break

        now = datetime.now(timezone.utc)

        # Calculate next run time
        next_run = now.replace(hour=DIGEST_HOUR_UTC, minute=0, second=0, microsecond=0)
        if now >= next_run:
            next_run += timedelta(days=1)

        wait_seconds = (next_run - now).total_seconds()
        logger.info(f"[Digest] Next run in {wait_seconds / 3600:.1f}h ({next_run.isoformat()})")

        # Wait (check shutdown every 60s)
        while wait_seconds > 0:
            if shutdown_event and shutdown_event.is_set():
                return
            sleep_time = min(wait_seconds, 60)
            await asyncio.sleep(sleep_time)
            wait_seconds -= sleep_time

        # Generate digests for yesterday
        yesterday = (datetime.now(timezone.utc) - timedelta(days=1)).date()
        await generate_digests_for_all_users(yesterday)


async def generate_digests_for_all_users(target_date: date):
    """Generate digests for all users that had conversations on target_date."""
    async with async_session() as db:
        # Find all users with conversations on that date
        day_start = datetime.combine(target_date, time.min, tzinfo=timezone.utc)
        day_end = datetime.combine(target_date, time.max, tzinfo=timezone.utc)

        users_query = (
            select(Conversation.user_id)
            .where(Conversation.started_at >= day_start)
            .where(Conversation.started_at <= day_end)
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
