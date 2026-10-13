"""User timezone helpers (single-user beta: one configured IANA zone)."""

import logging
from datetime import date, datetime, time, timedelta, timezone, tzinfo
from functools import lru_cache
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.core.config import settings

logger = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def user_zone() -> tzinfo:
    """The configured user timezone, or UTC when the tz database lacks it."""
    try:
        return ZoneInfo(settings.user_timezone)
    except (ZoneInfoNotFoundError, ValueError):
        logger.warning(
            "Timezone %r not available (install tzdata); falling back to UTC",
            settings.user_timezone,
        )
        return timezone.utc


def local_day_bounds(day: date) -> tuple[datetime, datetime]:
    """[start, end) of a calendar day in the user's timezone, as aware datetimes."""
    zone = user_zone()
    start = datetime.combine(day, time.min, tzinfo=zone)
    end = datetime.combine(day + timedelta(days=1), time.min, tzinfo=zone)
    return start, end


def to_user_local_date(moment: datetime) -> date:
    """Calendar date of a moment in the user's timezone (naive values are UTC)."""
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(user_zone()).date()
