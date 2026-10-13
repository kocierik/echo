"""Speaker detection based on audio energy proximity.

The wearable device is on the user's body, so the user's voice has
higher energy (closer to mic) than other speakers (further away).

Strategy:
- Collect energy values from recent segments
- Compute percentile 70 as threshold (user's voice dominates)
- Classify: energy >= threshold → "self", else → "other"
"""

import logging
import uuid
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)

CALIBRATION_SEGMENTS = 20


def compute_threshold(energies: list[int]) -> int | None:
    """Compute the speaker energy threshold from historical data.

    Uses percentile 70: the user's voice appears most often and loudest,
    so the 70th percentile separates "self" from "other".
    """
    if not energies:
        return None

    sorted_e = sorted(energies)
    idx = int(len(sorted_e) * 0.7)
    idx = min(idx, len(sorted_e) - 1)
    return sorted_e[idx]


def classify_energy(energy: int | None, threshold: int | None) -> str:
    """Classify a segment's speaker based on energy vs threshold."""
    if energy is None or threshold is None:
        return "unknown"
    return "self" if energy >= threshold else "other"


async def classify_segment(
    db: "AsyncSession",
    user_id: uuid.UUID,
    audio_energy: int | None,
    redis_client=None,
) -> str:
    """Classify a segment's speaker with auto-calibrating threshold.

    Args:
        db: Database session.
        user_id: User owning the segment.
        audio_energy: RMS energy value from the device.
        redis_client: Optional Redis for caching threshold.

    Returns:
        "self" | "other" | "unknown"
    """
    if audio_energy is None:
        return "unknown"

    from sqlalchemy import select

    from app.core.config import settings
    from app.models.segment import Segment

    # Check for manual override
    manual_threshold = getattr(settings, "speaker_energy_threshold", None)
    if manual_threshold and manual_threshold > 0:
        return classify_energy(audio_energy, manual_threshold)

    # Try cached threshold from Redis
    cache_key = f"speaker_threshold:{user_id}"
    if redis_client:
        try:
            cached = await redis_client.get(cache_key)
            if cached:
                return classify_energy(audio_energy, int(cached))
        except Exception:
            logger.exception("Redis unavailable for speaker threshold cache")

    # Calculate from recent segments
    recent_query = (
        select(Segment.audio_energy)
        .where(Segment.user_id == user_id)
        .where(Segment.audio_energy.isnot(None))
        .order_by(Segment.recorded_at.desc())
        .limit(100)
    )
    result = await db.execute(recent_query)
    energies = [row[0] for row in result.all()]

    if len(energies) < CALIBRATION_SEGMENTS:
        return "unknown"

    threshold = compute_threshold(energies)
    if threshold is None:
        return "unknown"

    # Cache in Redis for 1 hour
    if redis_client:
        try:
            await redis_client.set(cache_key, str(threshold), ex=3600)
        except Exception:
            logger.exception("Failed to cache speaker threshold in Redis")

    return classify_energy(audio_energy, threshold)
