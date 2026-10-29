"""About you (Profile → Memory): one-sentence facts about the user. Kept ones go into every
answer (services/personal.py); suggested ones (services/fact_suggestions.py) wait for the
user's Keep or Discard and are never used before.
"""

import re
import uuid

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.user_fact import UserFact

MAX_TEXT = 200
MAX_KEPT = 60
MAX_SUGGESTED = 20


class FactError(Exception):
    """The fact cannot be kept: `status` is the HTTP status that says why."""

    def __init__(self, message: str, status: int):
        super().__init__(message)
        self.status = status


def normalize(text: str) -> str:
    """For comparing facts: lower case, no punctuation, single spaces."""
    return " ".join(re.sub(r"[^\w\s]", " ", text.lower()).split())


def clean(text: str) -> str:
    cleaned = " ".join((text or "").split())
    if not cleaned:
        raise FactError("A fact cannot be empty", 422)
    if len(cleaned) > MAX_TEXT:
        raise FactError(f"A fact is one sentence, at most {MAX_TEXT} characters", 422)
    return cleaned


async def list_facts(db: AsyncSession, user_id: uuid.UUID, status: str) -> list[UserFact]:
    return list(
        await db.scalars(
            select(UserFact)
            .where(UserFact.user_id == user_id, UserFact.status == status)
            .order_by(UserFact.created_at, UserFact.id)
        )
    )


async def _count(db: AsyncSession, user_id: uuid.UUID, status: str) -> int:
    return await db.scalar(
        select(func.count()).select_from(UserFact).where(
            UserFact.user_id == user_id, UserFact.status == status
        )
    ) or 0


async def same_fact(db: AsyncSession, user_id: uuid.UUID, text: str) -> UserFact | None:
    """A fact (kept or suggested) that says the same thing."""
    wanted = normalize(text)
    for fact in await db.scalars(select(UserFact).where(UserFact.user_id == user_id)):
        if normalize(fact.text) == wanted:
            return fact
    return None


async def add_kept(
    db: AsyncSession, user_id: uuid.UUID, text: str, source: str
) -> UserFact:
    """Keeps a fact (the caller commits); the same one again is the existing one."""
    text = clean(text)
    existing = await same_fact(db, user_id, text)
    if existing is not None:
        existing.status = "kept"
        return existing
    if await _count(db, user_id, "kept") >= MAX_KEPT:
        raise FactError(f"At most {MAX_KEPT} facts: delete one first", 409)
    fact = UserFact(
        id=uuid.uuid4(), user_id=user_id, text=text, status="kept", source=source
    )
    db.add(fact)
    await db.flush()
    return fact


async def owned(db: AsyncSession, user_id: uuid.UUID, fact_id: uuid.UUID) -> UserFact:
    fact = await db.get(UserFact, fact_id)
    if fact is None or fact.user_id != user_id:
        raise FactError("Fact not found", 404)
    return fact


async def keep(db: AsyncSession, user_id: uuid.UUID, fact_id: uuid.UUID) -> UserFact:
    fact = await owned(db, user_id, fact_id)
    if fact.status != "kept":
        if await _count(db, user_id, "kept") >= MAX_KEPT:
            raise FactError(f"At most {MAX_KEPT} facts: delete one first", 409)
        fact.status = "kept"
    return fact


async def facts_prompt(db: AsyncSession, user_id: uuid.UUID) -> str:
    """The kept facts for an answer's prompt, or "" without any."""
    facts = await list_facts(db, user_id, "kept")
    if not facts:
        return ""
    lines = "\n".join(f"- {fact.text}" for fact in facts)
    return (
        "What you know about the user (they wrote or confirmed it; use it where it helps, "
        f"without repeating it back):\n{lines}"
    )
