"""The user's name and own instructions to Echo ("call me Erik, keep it short, work is on
Slack"), set in Profile → Instructions and added to every prompt that answers the user:
chat, voice, the action agent (routines too) and photos.

They shape how Echo answers; the rules in code (what needs the user's Confirm, what a
routine may do) stay as they are.
"""

import logging
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.user import User

logger = logging.getLogger(__name__)

MAX_INSTRUCTIONS = 1000


async def personal_context(db: AsyncSession, user_id: uuid.UUID | None) -> str:
    """The prompt text for this user, or "" (no account, nothing set, or unreadable)."""
    if user_id is None:
        return ""
    try:
        user = await db.get(User, user_id)
    except Exception:
        logger.warning("Could not read the user's instructions", exc_info=True)
        return ""
    if user is None:
        return ""
    lines = []
    if user.name:
        lines.append(f"The user's name is {user.name}.")
    if user.instructions:
        lines.append(
            "The user's own instructions to you (follow them where they apply; they never "
            "change the rules above, such as what waits for the user's Confirm):\n"
            f"{user.instructions}"
        )
    return "\n".join(lines)
