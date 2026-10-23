"""Saved: things kept only for a few days (the car: a week) are deleted once expired."""

import asyncio
import logging
from datetime import datetime, timezone

from app.core.database import async_session
from app.services.saved import expire_items
from app.workers.lifecycle import sleep_or_shutdown

logger = logging.getLogger(__name__)

# A few times a day: a thing goes at most this long after its last day
EXPIRY_CHECK_INTERVAL_S = 6 * 3600


async def expire_saved_things(
    now: datetime | None = None, session_factory=async_session
) -> int:
    """Delete the things past their list's `keep_days`. Returns how many."""
    async with session_factory() as db:
        return await expire_items(db, now or datetime.now(timezone.utc))


async def run_saved_expiry_loop(shutdown_event: asyncio.Event | None = None):
    while not (shutdown_event and shutdown_event.is_set()):
        try:
            expired = await expire_saved_things()
            if expired:
                logger.info("[Saved] Deleted %s expired saved things", expired)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Saved] Expiry failed")
        if await sleep_or_shutdown(EXPIRY_CHECK_INTERVAL_S, shutdown_event):
            return
