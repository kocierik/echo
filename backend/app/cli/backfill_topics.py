import argparse
import asyncio
import logging
from collections.abc import Sequence
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.services.llm_base import LLMMessage
from app.services.topics import normalize_topics
from app.workers.retry import retry_with_backoff

logger = logging.getLogger(__name__)

_TOPICS_SYSTEM_PROMPT = (
    "Given a conversation title and summary, identify up to 3 short topics "
    "(1-3 words each, in the conversation's language) naming what it is about. "
    "Never return a person's name. Answer in JSON with the format: "
    '{"topics": ["..."]}'
)


def _topics_messages(title: str | None, summary: str) -> list[LLMMessage]:
    return [
        LLMMessage(role="system", content=_TOPICS_SYSTEM_PROMPT),
        LLMMessage(
            role="user",
            content=f"Title: {title or ''}\nSummary: {summary}",
        ),
    ]


async def backfill_topics(
    *,
    days: int = 90,
    session_factory=None,
    llm_service=None,
    now: datetime | None = None,
) -> int:
    if not 1 <= days <= 3650:
        raise ValueError("days must be in 1..3650")

    if session_factory is None:
        from app.core.database import async_session

        session_factory = async_session
    if llm_service is None:
        from app.services.llm_openai import get_llm_analysis_service

        llm_service = get_llm_analysis_service()

    from app.models.conversation import Conversation

    effective_now = now or datetime.now(timezone.utc)
    if effective_now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    cutoff = effective_now - timedelta(days=days)
    from app.models.entity import Entity
    from app.models.entity_mention import EntityMention

    processed = 0
    attempted = 0

    async with session_factory() as db:
        conversations = (
            await db.scalars(
                select(Conversation)
                .where(Conversation.started_at >= cutoff)
                .where(Conversation.started_at <= effective_now)
                .where(Conversation.summary.is_not(None))
                .where(Conversation.topics.is_(None))
                .order_by(Conversation.started_at, Conversation.id)
            )
        ).all()

        for conversation in conversations:
            attempted += 1
            names = (
                await db.scalars(
                    select(Entity.name)
                    .join(EntityMention, EntityMention.entity_id == Entity.id)
                    .where(EntityMention.conversation_id == conversation.id)
                    .where(Entity.user_id == conversation.user_id)
                    .where(Entity.entity_type == "person")
                )
            ).all()
            messages = _topics_messages(conversation.title, conversation.summary)

            async def complete_json_safely():
                try:
                    return await llm_service.complete_json(messages)
                except Exception as exc:
                    # The retry logger may include exception messages; keep summaries private.
                    raise RuntimeError(type(exc).__name__) from None

            try:
                result = await retry_with_backoff(
                    complete_json_safely,
                    operation_name=f"Topic backfill conversation {conversation.id}",
                )
            except Exception:
                logger.warning("[Topic backfill] Failed for conversation %s", conversation.id)
            else:
                conversation.topics = normalize_topics(result.get("topics"), names) or None
                processed += 1

            if attempted % 20 == 0:
                await db.commit()

        if attempted % 20:
            await db.commit()

    return processed


def parse_args(argv: Sequence[str] | None = None):
    parser = argparse.ArgumentParser(prog="python -m app.cli.backfill_topics")
    parser.add_argument("--days", type=int, default=90)
    args = parser.parse_args(argv)
    if not 1 <= args.days <= 3650:
        parser.error("--days must be in 1..3650")
    return args


def main(argv: Sequence[str] | None = None) -> None:
    args = parse_args(argv)
    print(asyncio.run(backfill_topics(days=args.days)))


if __name__ == "__main__":
    main()
