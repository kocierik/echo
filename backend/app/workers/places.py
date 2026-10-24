"""Places visited: visits are kept 90 days, then deleted."""

import asyncio
import logging
from datetime import datetime, timezone

from app.core.database import async_session
from app.services.places import expire_visits
from app.workers.lifecycle import sleep_or_shutdown

logger = logging.getLogger(__name__)

# A few times a day: a visit goes at most this long after its 90th day
CLEANUP_INTERVAL_S = 6 * 3600


async def expire_old_visits(now: datetime | None = None, session_factory=async_session) -> int:
    """Delete the visits older than 90 days. Returns how many."""
    async with session_factory() as db:
        return await expire_visits(db, now or datetime.now(timezone.utc))


async def run_places_cleanup_loop(shutdown_event: asyncio.Event | None = None):
    while not (shutdown_event and shutdown_event.is_set()):
        try:
            deleted = await expire_old_visits()
            if deleted:
                logger.info("[Places] Deleted %s visits older than 90 days", deleted)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Places] Cleanup failed")
        if await sleep_or_shutdown(CLEANUP_INTERVAL_S, shutdown_event):
            return
