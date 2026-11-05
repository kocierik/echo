"""Plans: how much speech a month each account's plan transcribes, and what follows it.

A plan is configuration, not copy: monthly minutes of speech, the minutes a day still
transcribed at once once they are used, web searches a day and routines. The defaults
below can be changed per plan with `PLANS` in .env (JSON, e.g. {"plus": {"monthly_minutes":
1200}}). The account's plan is `users.plan`, set by the operator (`make set-plan`); a key
with no account row is on free.

Usage is what transcription already records: the `stt` seconds in `llm_usage` for the
calendar month (UTC), so the budget resets on the 1st. Past the budget nothing is lost:
the STT worker transcribes the day's allowance at once and marks the rest `deferred`
(workers/stt.py), and deferred speech is transcribed, oldest first, when the budget allows
again (workers/deferred.py). It counts on the month it is transcribed in.
"""

import uuid
from dataclasses import dataclass
from datetime import date, datetime, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.llm_usage import LlmUsage
from app.models.segment import Segment
from app.models.user import User
from app.services.passwords import normalize_email

FREE = "free"

# To be revised with the prices (docs/superpowers/specs/2026-10-24-plans-and-quotas-design.md)
DEFAULT_PLANS: dict[str, dict[str, int]] = {
    # premium_voice: 1 when spoken answers may use Echo's natural voices (services/speech.py)
    "free": {
        "monthly_minutes": 300, "daily_minutes": 10, "web_searches_per_day": 5, "routines": 2,
        "premium_voice": 0,
    },
    "plus": {
        "monthly_minutes": 1500, "daily_minutes": 10, "web_searches_per_day": 30, "routines": 10,
        "premium_voice": 1,
    },
    # Fair use: about 5 hours a day
    "unlimited": {
        "monthly_minutes": 9000, "daily_minutes": 10, "web_searches_per_day": 60, "routines": 10,
        "premium_voice": 1,
    },
}


@dataclass(frozen=True)
class Plan:
    name: str
    monthly_minutes: int
    # Past the monthly budget, the first minutes of each day still transcribed at once
    daily_minutes: int
    web_searches_per_day: int
    routines: int
    # 1: spoken answers may use Echo's natural voices; 0: the phone's own
    premium_voice: int = 0


def plan_names() -> list[str]:
    return list(dict.fromkeys([*DEFAULT_PLANS, *settings.plans]))


def get_plan(name: str | None) -> Plan:
    """The plan by name, with the settings' changes; an unknown name is free."""
    if name not in plan_names():
        name = FREE
    values = {
        **DEFAULT_PLANS[FREE],
        **DEFAULT_PLANS.get(name, {}),
        **settings.plans.get(name, {}),
    }
    return Plan(name=name, **{field: int(values[field]) for field in DEFAULT_PLANS[FREE]})


async def user_plan(db: AsyncSession, user_id: uuid.UUID) -> Plan:
    return get_plan(await db.scalar(select(User.plan).where(User.id == user_id)))


def _today() -> date:
    return datetime.now(timezone.utc).date()


def month_start(day: date) -> date:
    return day.replace(day=1)


def next_month_start(day: date) -> date:
    if day.month == 12:
        return date(day.year + 1, 1, 1)
    return date(day.year, day.month + 1, 1)


async def speech_seconds(db: AsyncSession, user_id: uuid.UUID, since: date) -> int:
    """Seconds of speech transcribed for the user from `since` (a UTC day) on."""
    total = await db.scalar(
        select(func.coalesce(func.sum(LlmUsage.input_units), 0)).where(
            LlmUsage.user_id == user_id,
            LlmUsage.kind == "stt",
            LlmUsage.day >= since,
        )
    )
    return int(total or 0)


async def deferred_seconds(db: AsyncSession, user_id: uuid.UUID) -> int:
    """Seconds of speech waiting for the budget."""
    total = await db.scalar(
        select(func.coalesce(func.sum(Segment.duration_ms), 0)).where(
            Segment.user_id == user_id, Segment.transcription_status == "deferred"
        )
    )
    return int(total or 0) // 1000


async def may_transcribe(
    db: AsyncSession, user_id: uuid.UUID, *, late: bool, today: date | None = None
) -> bool:
    """Whether a segment is transcribed now. Within the month's budget always; past it,
    only today's first minutes, and never for `late` (deferred) speech, which waits for
    the budget so it does not take the allowance meant for what is said today."""
    today = today or _today()
    plan = await user_plan(db, user_id)
    if await speech_seconds(db, user_id, month_start(today)) < plan.monthly_minutes * 60:
        return True
    if late:
        return False
    return await speech_seconds(db, user_id, today) < plan.daily_minutes * 60


@dataclass
class PlanUsage:
    plan: Plan
    used_seconds: int
    deferred_seconds: int
    # The first day of the next month (UTC): the budget starts again
    resets_on: date

    @property
    def budget_seconds(self) -> int:
        return self.plan.monthly_minutes * 60

    @property
    def over_budget(self) -> bool:
        return self.used_seconds >= self.budget_seconds


async def plan_usage(db: AsyncSession, user_id: uuid.UUID, today: date | None = None) -> PlanUsage:
    today = today or _today()
    return PlanUsage(
        plan=await user_plan(db, user_id),
        used_seconds=await speech_seconds(db, user_id, month_start(today)),
        deferred_seconds=await deferred_seconds(db, user_id),
        resets_on=next_month_start(today),
    )


async def set_user_plan(db: AsyncSession, email: str, plan: str) -> User:
    """Puts the account on `plan` (the operator's command until payments exist)."""
    plan = plan.strip().lower()
    if plan not in plan_names():
        raise ValueError(f"unknown plan {plan!r}: one of {', '.join(plan_names())}")
    user = await db.scalar(select(User).where(User.email == normalize_email(email)))
    if user is None:
        raise ValueError("no such user")
    user.plan = plan
    await db.commit()
    return user
