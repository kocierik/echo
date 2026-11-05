"""The user's name, own instructions to Echo ("call me Erik, keep it short, work is on
Slack"), the facts Echo keeps about them (Profile → Memory → About you) and their last two
weeks of the iPhone's Health app (Profile → Health, services/health.py), added to every
prompt that answers the user: chat, voice, the action agent (routines too) and photos.

They shape how Echo answers; the rules in code (what needs the user's Confirm, what a
routine may do) stay as they are.
"""

import logging
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.user import User
from app.services.health import health_context
from app.services.user_facts import facts_prompt

logger = logging.getLogger(__name__)

MAX_INSTRUCTIONS = 1000


async def personal_context(db: AsyncSession, user_id: uuid.UUID | None) -> str:
    """The prompt text for this user, or "" (no account, nothing set, or unreadable)."""
    if user_id is None:
        return ""
    try:
        user = await db.get(User, user_id)
        facts = await facts_prompt(db, user_id)
        body = await health_context(db, user_id)
    except Exception:
        logger.warning("Could not read the user's instructions", exc_info=True)
        return ""
    lines = []
    if user is None:
        return "\n".join(part for part in (facts, body) if part)
    if user.name:
        lines.append(f"The user's name is {user.name}.")
    if user.instructions:
        lines.append(
            "The user's own instructions to you (follow them where they apply; they never "
            "change the rules above, such as what waits for the user's Confirm):\n"
            f"{user.instructions}"
        )
    if facts:
        lines.append(facts)
    if body:
        lines.append(body)
    return "\n".join(lines)
