"""Weekly summary: the week (Monday to Sunday, user's timezone) from its days.

Written on Monday after the digest of Sunday, from what is already condensed: the daily
summaries, the conversations' titles and summaries, who came up most and how many tasks
were noted. One cheap LLM call per week.
"""

import logging
import uuid
from datetime import date, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timezone import local_day_bounds
from app.models.conversation import Conversation
from app.models.digest import Digest
from app.models.entity import Entity
from app.models.entity_mention import EntityMention
from app.models.weekly_digest import WeeklyDigest
from app.services.llm_base import LLMMessage, LLMService
from app.services.temporal import conversation_overlaps

logger = logging.getLogger(__name__)

MAX_INPUT_CHARS = 8000
MAX_HIGHLIGHTS = 5
MAX_PEOPLE = 8

WEEKLY_PROMPT = (
    "You are a personal assistant. Summarize the user's week from the summaries of their "
    "days and conversations (often in Italian).\n"
    "Write in English, in the first person as the user, keeping the names of people and "
    "places as spoken. Reply with ONLY a JSON object:\n"
    '{"summary": "4-6 sentences: what the week was about, decisions, progress", '
    '"highlights": ["up to 5 short lines: decisions, news, things to follow up"]}'
)


def week_start_of(day: date) -> date:
    """The Monday of the week `day` is in."""
    return day - timedelta(days=day.weekday())


def week_bounds(week_start: date):
    start, _ = local_day_bounds(week_start)
    _, end = local_day_bounds(week_start + timedelta(days=6))
    return start, end


async def _people_of_the_week(db: AsyncSession, user_id: uuid.UUID, conversation_ids) -> list:
    counted = func.count(func.distinct(EntityMention.conversation_id))
    rows = (
        await db.execute(
            select(Entity.name, counted.label("conversations"))
            .join(EntityMention, EntityMention.entity_id == Entity.id)
            .where(Entity.user_id == user_id, Entity.entity_type == "person")
            .where(EntityMention.conversation_id.in_(conversation_ids))
            .group_by(Entity.name)
            .order_by(counted.desc(), Entity.name)
            .limit(MAX_PEOPLE)
        )
    ).all()
    return [{"name": row.name, "conversations": row.conversations} for row in rows]


async def generate_weekly_digest(
    db: AsyncSession,
    user_id: uuid.UUID,
    week_start: date,
    llm: LLMService,
    *,
    replace: bool = False,
) -> WeeklyDigest | None:
    """The week's summary, or None when nothing was recorded that week.

    An existing one is returned as is, unless `replace`.
    """
    if week_start.weekday() != 0:
        raise ValueError("week_start must be a Monday")
    existing = (
        await db.execute(
            select(WeeklyDigest).where(
                WeeklyDigest.user_id == user_id, WeeklyDigest.week_start == week_start
            )
        )
    ).scalar_one_or_none()
    if existing is not None and not replace:
        return existing

    start, end = week_bounds(week_start)
    conversations = (
        await db.execute(
            select(Conversation)
            .where(Conversation.user_id == user_id)
            .where(*conversation_overlaps(start, end))
            .order_by(Conversation.started_at)
        )
    ).scalars().all()
    if not conversations:
        return None

    days = (
        await db.execute(
            select(Digest)
            .where(Digest.user_id == user_id)
            .where(Digest.digest_date >= week_start)
            .where(Digest.digest_date <= week_start + timedelta(days=6))
            .order_by(Digest.digest_date)
        )
    ).scalars().all()
    people = await _people_of_the_week(db, user_id, [c.id for c in conversations])
    tasks_created = (
        await db.execute(
            select(func.count(Entity.id))
            .where(Entity.user_id == user_id, Entity.entity_type == "task")
            .where(Entity.created_at >= start, Entity.created_at < end)
        )
    ).scalar_one()

    lines = [f"Week of {week_start:%d/%m/%Y}: {len(conversations)} conversations."]
    if days:
        lines.append("Daily summaries:")
        lines += [f"- {d.digest_date:%a %d/%m}: {d.summary}" for d in days]
    lines.append("Conversations:")
    lines += [
        f"- {c.started_at:%a %d/%m}: {c.title or 'Conversation'}"
        + (f": {c.summary}" if c.summary else "")
        for c in conversations
    ]
    if people:
        lines.append(
            "People who came up: "
            + ", ".join(f"{p['name']} ({p['conversations']})" for p in people)
        )
    reply = await llm.complete_json(
        [
            LLMMessage(role="system", content=WEEKLY_PROMPT),
            LLMMessage(role="user", content="\n".join(lines)[:MAX_INPUT_CHARS]),
        ],
        temperature=0.3,
    )
    summary = str(reply.get("summary") or "").strip()
    if not summary:
        raise ValueError("The model returned no weekly summary")
    highlights = [
        str(h).strip() for h in (reply.get("highlights") or []) if str(h).strip()
    ][:MAX_HIGHLIGHTS]

    if existing is not None:
        await db.delete(existing)
        await db.flush()
    weekly = WeeklyDigest(
        user_id=user_id,
        week_start=week_start,
        summary=summary,
        highlights=highlights,
        people=people,
        conversation_count=len(conversations),
        tasks_created=tasks_created,
    )
    db.add(weekly)
    await db.commit()
    logger.info(f"[Weekly] Summary for {user_id}, week of {week_start}")
    return weekly
