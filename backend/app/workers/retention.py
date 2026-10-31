"""Delete expired audio while preserving segment metadata.

Transcribed audio goes after `completed_audio_retention_hours`, audio that failed after
`incomplete_audio_retention_days`; deferred audio waits for its transcription. Tracked
runs and their steps (core/runs.py) go after `run_retention_days`.
"""

import asyncio
import logging
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from pathlib import Path

from sqlalchemy import and_, or_, select

from app.core.config import settings
from app.core.database import async_session
from app.core.runs import purge_older_than
from app.models.segment import Segment
from app.workers.lifecycle import sleep_or_shutdown

logger = logging.getLogger(__name__)

# Run retention check every 6 hours
RETENTION_CHECK_INTERVAL_S = 6 * 3600
RETENTION_BATCH_SIZE = 100

DeleteFile = Callable[[Path], None]


def _delete_audio_file(audio_file: Path) -> None:
    audio_file.unlink()


def _build_retention_query(now: datetime):
    if now.tzinfo is None or now.utcoffset() != timedelta(0):
        raise ValueError("now must be UTC-aware")

    completed_cutoff = now - timedelta(hours=settings.completed_audio_retention_hours)
    incomplete_cutoff = now - timedelta(days=settings.incomplete_audio_retention_days)

    return (
        select(Segment)
        .where(Segment.audio_path.isnot(None))
        .where(Segment.audio_path != "")
        .where(
            or_(
                and_(
                    Segment.transcription_status == "completed",
                    Segment.recorded_at < completed_cutoff,
                ),
                # Deferred speech (past the plan's budget) keeps its audio until it is
                # transcribed: it is late, never lost (services/plans.py)
                and_(
                    Segment.transcription_status != "completed",
                    Segment.transcription_status != "deferred",
                    Segment.recorded_at < incomplete_cutoff,
                ),
            )
        )
        .order_by(Segment.recorded_at.asc(), Segment.id.asc())
        .limit(RETENTION_BATCH_SIZE)
        .with_for_update(skip_locked=True)
    )


async def run_retention_loop(shutdown_event: asyncio.Event | None = None):
    """Periodically clear audio using the completed and incomplete policies."""
    logger.info(
        "[Retention] Started: completed audio expires after %sh; "
        "incomplete audio expires after %sd (checking every %sh)",
        settings.completed_audio_retention_hours,
        settings.incomplete_audio_retention_days,
        RETENTION_CHECK_INTERVAL_S // 3600,
    )

    while not (shutdown_event and shutdown_event.is_set()):
        try:
            cleared = await cleanup_old_audio()
            if cleared > 0:
                logger.info("[Retention] Cleared %s expired audio records", cleared)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Retention] Error during cleanup")

        # Run tracking (core/runs.py), on its own: a failure here never stops the audio
        # cleanup above, nor the other way round
        try:
            purged = await purge_older_than(settings.run_retention_days)
            if purged > 0:
                logger.info("[Retention] Deleted %s tracked runs", purged)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Retention] Error while deleting old tracked runs")

        if await sleep_or_shutdown(RETENTION_CHECK_INTERVAL_S, shutdown_event):
            return


async def cleanup_old_audio(
    *,
    now: datetime | None = None,
    session_factory=async_session,
    delete_file: DeleteFile = _delete_audio_file,
) -> int:
    """Delete one expired audio batch and clear its storage metadata.

    Returns:
        Number of segment records whose audio fields were successfully cleared.
        Missing files count as successfully cleared; deletion errors remain for retry.
    """
    effective_now = now or datetime.now(timezone.utc)
    query = _build_retention_query(effective_now)
    cleared_count = 0

    async with session_factory() as db:
        result = await db.execute(query)
        segments = result.scalars().all()

        for segment in segments:
            audio_path = segment.audio_path
            if not audio_path:
                continue

            audio_file = Path(audio_path)
            try:
                delete_file(audio_file)
            except FileNotFoundError:
                pass
            except OSError as exc:
                logger.warning("[Retention] Failed to delete %s: %s", audio_file, exc)
                continue

            segment.audio_path = None
            segment.audio_size_bytes = None
            cleared_count += 1

        await db.commit()

    return cleared_count
