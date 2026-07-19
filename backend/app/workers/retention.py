"""Audio retention job: deletes audio files older than AUDIO_RETENTION_DAYS."""

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import async_session
from app.models.segment import Segment

logger = logging.getLogger(__name__)

# Run retention check every 6 hours
RETENTION_CHECK_INTERVAL_S = 6 * 3600


async def run_retention_loop():
    """Periodically delete audio files older than the retention period."""
    logger.info(
        f"[Retention] Started — deleting audio older than {settings.audio_retention_days} days "
        f"(checking every {RETENTION_CHECK_INTERVAL_S // 3600}h)"
    )

    while True:
        try:
            deleted = await cleanup_old_audio()
            if deleted > 0:
                logger.info(f"[Retention] Cleaned up {deleted} expired audio files")
        except Exception as e:
            logger.error(f"[Retention] Error during cleanup: {e}")

        await asyncio.sleep(RETENTION_CHECK_INTERVAL_S)


async def cleanup_old_audio() -> int:
    """Delete audio files and clear paths for segments older than retention period.

    Returns:
        Number of audio files deleted.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=settings.audio_retention_days)
    deleted_count = 0

    async with async_session() as db:
        # Find segments with audio files that are past retention
        query = (
            select(Segment)
            .where(Segment.recorded_at < cutoff)
            .where(Segment.audio_path.isnot(None))
            .where(Segment.audio_path != "")
            .limit(100)  # Process in batches
        )

        result = await db.execute(query)
        segments = result.scalars().all()

        for segment in segments:
            # Delete the file
            audio_file = Path(segment.audio_path)
            if audio_file.exists():
                try:
                    audio_file.unlink()
                    deleted_count += 1
                except OSError as e:
                    logger.warning(f"[Retention] Failed to delete {audio_file}: {e}")
                    continue

            # Clear the path in DB (keep the segment record)
            segment.audio_path = ""
            segment.audio_size_bytes = 0

        await db.commit()

    return deleted_count
