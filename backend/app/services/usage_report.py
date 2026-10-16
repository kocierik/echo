"""The cost of a day of Echo, per user and kind of work (`make usage`)."""

import uuid
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.action_log import ActionLog
from app.models.llm_usage import LlmUsage
from app.models.user import User
from app.usage_prices import PRICES, PRICES_READ_ON


@dataclass
class DayCost:
    user_id: uuid.UUID | None
    email: str | None
    day: date
    kind: str
    model: str
    calls: int
    input_units: int
    output_units: int
    cached_units: int
    usd: float | None


def cost(model: str, input_units: int, output_units: int, cached_units: int) -> float | None:
    """USD for these units of `model`; None when the model has no price."""
    price = PRICES.get(model)
    if price is None:
        return None
    if price["unit"] == "second":
        return input_units / 60 * price["per_minute"]
    fresh = max(input_units - cached_units, 0)
    return (
        fresh * price["input"] + cached_units * price["cached"] + output_units * price["output"]
    ) / 1_000_000


async def usage_report(db: AsyncSession, days: int) -> list[DayCost]:
    """The last `days` days (UTC, today included), oldest first."""
    since = datetime.now(timezone.utc).date() - timedelta(days=days - 1)
    rows = (
        await db.execute(
            select(LlmUsage, User.email)
            .outerjoin(User, User.id == LlmUsage.user_id)
            .where(LlmUsage.day >= since)
            .order_by(LlmUsage.day, LlmUsage.kind, LlmUsage.model)
        )
    ).all()
    return [
        DayCost(
            user_id=usage.user_id, email=email, day=usage.day, kind=usage.kind,
            model=usage.model, calls=usage.calls, input_units=usage.input_units,
            output_units=usage.output_units, cached_units=usage.cached_units,
            usd=cost(usage.model, usage.input_units, usage.output_units, usage.cached_units),
        )
        for usage, email in rows
    ]


async def composio_actions(db: AsyncSession, days: int) -> dict[uuid.UUID, int]:
    """Actions run in connected apps per user (no price here: Composio bills apart)."""
    since = datetime.now(timezone.utc) - timedelta(days=days)
    rows = (
        await db.execute(
            select(ActionLog.user_id, func.count())
            .where(ActionLog.outcome == "ok", ActionLog.created_at >= since)
            .group_by(ActionLog.user_id)
        )
    ).all()
    return {user_id: count for user_id, count in rows}


def _usd(value: float | None) -> str:
    return "?" if value is None else f"${value:.2f}"


def summarize(rows: list[DayCost], actions: dict[uuid.UUID, int]) -> str:
    """Per user: each day's total, the average day, each kind, and the cost per hour of
    speech (everything the user cost, over the hours transcribed)."""
    lines = [f"Prices read on {PRICES_READ_ON} (app/usage_prices.py; check them)."]
    by_user: dict = defaultdict(list)
    for row in rows:
        by_user[(row.user_id, row.email)].append(row)
    for (user_id, email), user_rows in by_user.items():
        unknown = any(row.usd is None for row in user_rows)
        total = sum(row.usd or 0 for row in user_rows)
        days: dict = defaultdict(float)
        kinds: dict = defaultdict(float)
        for row in user_rows:
            days[row.day] += row.usd or 0
            kinds[row.kind] += row.usd or 0
        speech_seconds = sum(r.input_units for r in user_rows if r.kind == "stt")
        mark = " + ?" if unknown else ""
        lines.append("")
        lines.append(f"{email or 'no account'} ({user_id or 'unowned work'})")
        for day, usd in sorted(days.items()):
            lines.append(f"  {day}  ${usd:.2f}{mark}")
        lines.append(f"  average day  ${total / len(days):.2f}{mark}")
        for kind, usd in sorted(kinds.items()):
            unknown_kind = any(r.usd is None for r in user_rows if r.kind == kind)
            lines.append(f"  {kind:16} {_usd(None if unknown_kind else usd)}")
        if speech_seconds:
            per_hour = total / (speech_seconds / 3600)
            lines.append(f"  ${per_hour:.2f} per hour of speech{mark}")
        lines.append(f"  Composio actions: {actions.get(user_id, 0)}")
    return "\n".join(lines)
