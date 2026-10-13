"""Temporal filter extraction from natural language queries.

Parses time references like "ieri", "questa settimana", "lunedì scorso"
and converts them to date ranges for filtering.
"""

import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone


def conversation_overlaps(date_from: datetime | None, date_to: datetime | None) -> list:
    """SQL conditions selecting conversations that overlap [date_from, date_to).

    A conversation spans started_at → ended_at (ended_at is NULL while it has a
    single segment), so filtering by started_at alone would hide a conversation
    that began before the period, e.g. across midnight. Either bound may be open.
    """
    from sqlalchemy import func

    from app.models.conversation import Conversation

    conditions = []
    if date_to is not None:
        conditions.append(Conversation.started_at < date_to)
    if date_from is not None:
        conversation_end = func.coalesce(Conversation.ended_at, Conversation.started_at)
        conditions.append(conversation_end >= date_from)
    return conditions


@dataclass
class DateRange:
    """A date range filter extracted from a query.

    Extracted ranges always have both ends; explicit API filters may leave one
    end open (None).
    """

    date_from: datetime | None
    date_to: datetime | None

    def __repr__(self) -> str:
        start = self.date_from.date() if self.date_from else "…"
        end = self.date_to.date() if self.date_to else "…"
        return f"DateRange({start} → {end})"


# Italian day names → weekday index (Monday=0)
GIORNI_IT = {
    "lunedì": 0, "lunedi": 0,
    "martedì": 1, "martedi": 1,
    "mercoledì": 2, "mercoledi": 2,
    "giovedì": 3, "giovedi": 3,
    "venerdì": 4, "venerdi": 4,
    "sabato": 5,
    "domenica": 6,
}

# English day names → weekday index
DAYS_EN = {
    "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
    "friday": 4, "saturday": 5, "sunday": 6,
}

MONTHS_IT = {
    "gennaio": 1, "febbraio": 2, "marzo": 3, "aprile": 4,
    "maggio": 5, "giugno": 6, "luglio": 7, "agosto": 8,
    "settembre": 9, "ottobre": 10, "novembre": 11, "dicembre": 12,
}

MONTHS_EN = {
    "january": 1, "february": 2, "march": 3, "april": 4,
    "may": 5, "june": 6, "july": 7, "august": 8,
    "september": 9, "october": 10, "november": 11, "december": 12,
}


def _start_of_day(d: date) -> datetime:
    """Get start of day as timezone-aware datetime."""
    return datetime(d.year, d.month, d.day, tzinfo=timezone.utc)


def _end_of_day(d: date) -> datetime:
    """Get end of day as timezone-aware datetime."""
    return datetime(d.year, d.month, d.day, 23, 59, 59, tzinfo=timezone.utc)


def _last_weekday(target_weekday: int, today: date) -> date:
    """Find the most recent occurrence of a weekday before today."""
    days_back = (today.weekday() - target_weekday) % 7
    if days_back == 0:
        days_back = 7  # "lunedì" means last Monday, not today
    return today - timedelta(days=days_back)


def _parse_absolute_date(day: int, month: int, year: int | None, now: datetime) -> DateRange | None:
    """Build a one-day range for an explicit calendar date."""
    try:
        target_date = date(year or now.year, month, day)
    except ValueError:
        return None
    return DateRange(_start_of_day(target_date), _end_of_day(target_date))


def extract_date_range(query: str, now: datetime | None = None) -> DateRange | None:
    """Extract a date range from a natural language query.

    Supports Italian and English temporal expressions:
    - "ieri" / "yesterday"
    - "oggi" / "today"
    - "questa settimana" / "this week"
    - "settimana scorsa" / "last week"
    - "questo mese" / "this month"
    - "mese scorso" / "last month"
    - "lunedì scorso" / "last monday" (etc.)
    - "ultimi N giorni" / "last N days"
    - "N giorni fa" / "N days ago"
    - "7 ottobre" / "7/10" / "7 ottobre 2026"

    Args:
        query: The user's natural language question.
        now: Current datetime (for testing). Defaults to UTC now.

    Returns:
        DateRange if a temporal reference is found, None otherwise.
    """
    if now is None:
        now = datetime.now(timezone.utc)

    today = now.date()
    q = query.lower().strip()

    # --- explicit absolute dates: "7 ottobre", "7 ottobre 2026", "7/10/2026" ---
    absolute_patterns = [
        r"\b(?:il\s+)?(\d{1,2})\s+(?:di\s+)?([a-zàèéìòù]+)(?:\s+(\d{4}))?\b",
        r"\b(?:il\s+)?(\d{1,2})\s*[/.-]\s*(\d{1,2})(?:\s*[/.-]\s*(\d{4}))?\b",
    ]
    for pattern in absolute_patterns:
        match = re.search(pattern, q)
        if not match:
            continue
        if len(match.groups()) == 3:
            day, month_name_or_num, year = match.groups()
        else:
            day, month_name_or_num = match.groups()
            year = None

        if month_name_or_num is not None and month_name_or_num.isdigit():
            month = int(month_name_or_num)
        else:
            month_key = month_name_or_num.lower()
            month = MONTHS_IT.get(month_key) or MONTHS_EN.get(month_key)
            if month is None:
                continue

        day_int = int(day)
        year_int = int(year) if year is not None else None
        if day_int <= 0 or month <= 0 or month > 12:
            continue
        result = _parse_absolute_date(day_int, month, year_int, now)
        if result is not None:
            return result

    # --- "ieri" / "yesterday" ---
    if re.search(r"\bieri\b", q) or re.search(r"\byesterday\b", q):
        yesterday = today - timedelta(days=1)
        return DateRange(_start_of_day(yesterday), _end_of_day(yesterday))

    # --- "oggi" / "today" ---
    if re.search(r"\boggi\b", q) or re.search(r"\btoday\b", q):
        return DateRange(_start_of_day(today), _end_of_day(today))

    # --- "questa settimana" / "this week" ---
    if re.search(r"\bquesta settimana\b", q) or re.search(r"\bthis week\b", q):
        monday = today - timedelta(days=today.weekday())
        return DateRange(_start_of_day(monday), _end_of_day(today))

    # --- "settimana scorsa" / "last week" ---
    if re.search(r"\bsettimana scorsa\b", q) or re.search(r"\blast week\b", q):
        last_monday = today - timedelta(days=today.weekday() + 7)
        last_sunday = last_monday + timedelta(days=6)
        return DateRange(_start_of_day(last_monday), _end_of_day(last_sunday))

    # --- "questo mese" / "this month" ---
    if re.search(r"\bquesto mese\b", q) or re.search(r"\bthis month\b", q):
        first_of_month = today.replace(day=1)
        return DateRange(_start_of_day(first_of_month), _end_of_day(today))

    # --- "mese scorso" / "last month" ---
    if re.search(r"\bmese scorso\b", q) or re.search(r"\blast month\b", q):
        first_of_this_month = today.replace(day=1)
        last_day_prev = first_of_this_month - timedelta(days=1)
        first_of_prev = last_day_prev.replace(day=1)
        return DateRange(_start_of_day(first_of_prev), _end_of_day(last_day_prev))

    # --- "ultimi N giorni" / "last N days" ---
    m = re.search(r"\bultim[io]\s+(\d+)\s+giorn[io]", q)
    if not m:
        m = re.search(r"\blast\s+(\d+)\s+days?\b", q)
    if m:
        n = int(m.group(1))
        start = today - timedelta(days=n)
        return DateRange(_start_of_day(start), _end_of_day(today))

    # --- "N giorni fa" / "N days ago" ---
    m = re.search(r"\b(\d+)\s+giorn[io]\s+fa\b", q)
    if not m:
        m = re.search(r"\b(\d+)\s+days?\s+ago\b", q)
    if m:
        n = int(m.group(1))
        target = today - timedelta(days=n)
        return DateRange(_start_of_day(target), _end_of_day(target))

    # --- Italian weekday + "scorso" (e.g. "lunedì scorso") ---
    for giorno, weekday_idx in GIORNI_IT.items():
        if re.search(rf"\b{giorno}\s+scors[oa]?\b", q) or re.search(rf"\b{giorno}\b", q):
            target = _last_weekday(weekday_idx, today)
            return DateRange(_start_of_day(target), _end_of_day(target))

    # --- English "last <weekday>" ---
    for day, weekday_idx in DAYS_EN.items():
        if re.search(rf"\blast\s+{day}\b", q) or re.search(rf"\b{day}\b", q):
            target = _last_weekday(weekday_idx, today)
            return DateRange(_start_of_day(target), _end_of_day(target))

    return None
