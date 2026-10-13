"""Chat action detection — detect and execute user intents (calendar, tasks, etc.)."""

import json
import logging
import re
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timezone import to_user_local_date
from app.services.calendar_service import (
    create_event,
    delete_event,
    find_events,
    list_events,
    update_event,
)
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_query_service

logger = logging.getLogger(__name__)

# Actions the chat can perform
AVAILABLE_ACTIONS = """
Available actions you can take:
1. calendar_list — List events for a period (params: date_from YYYY-MM-DD, date_to YYYY-MM-DD)
2. calendar_create — Create an event (params: summary, date YYYY-MM-DD,
   time HH:MM optional, duration_minutes optional, location optional)
3. calendar_update — Update an existing event (params: target, then only the fields
   that change: summary, date, time, duration_minutes, location)
4. calendar_delete — Delete an existing event (params: target)
5. none — No action needed, just answer the question

"target" identifies the existing event: {{"summary": "its current title",
"date": "its current date YYYY-MM-DD, if known"}}.
"""

DETECT_PROMPT = """You are an intent classifier for a personal assistant chat.
The user may ask questions about their memory OR request actions on calendar events
(create, read, modify, delete).

Determine if the user's message requires an ACTION or is just a QUESTION about their
past conversations/memory.

{actions}

Respond with ONLY a JSON object:
- Question about memory/past conversations: {{"action": "none"}}
- Calendar list:
  {{"action": "calendar_list", "params": {{"date_from": "YYYY-MM-DD", "date_to": "YYYY-MM-DD"}}}}
  - "domani" = tomorrow's date for both date_from and date_to
  - "questa settimana" = today to end of week
  - "prossima settimana" = next monday to next sunday
- Calendar create:
  {{"action": "calendar_create", "params": {{"summary": "...", "date": "YYYY-MM-DD",
  "time": "HH:MM", "duration_minutes": 60, "location": "..."}}}}
  - "dalle 15 alle 17" = time "15:00", duration_minutes 120; "mezz'ora" = 30
  - omit time if no time is said
  - omit duration_minutes if no duration or end time is said
- Calendar update:
  {{"action": "calendar_update", "params": {{"target": {{"summary": "Dentista",
  "date": "YYYY-MM-DD"}}, "time": "18:00"}}}}
  - include only the fields that change
  - a new time alone keeps the date, a new date alone keeps the time
- Calendar delete:
  {{"action": "calendar_delete", "params": {{"target": {{"summary": "Dentista"}}}}}}
- For "spostalo", "cancellalo" or a reply to a question about which event, take the
  target from the recent conversation.

Today's date: {today}
Tomorrow's date: {tomorrow}

Only return the JSON, nothing else."""

# Words that may introduce a calendar request (prefix match, IT + EN). Messages
# without them skip the intent classifier and go straight to RAG.
_CALENDAR_HINT = re.compile(
    r"\b(calendar|calendario|agenda|event|appuntament|appointment|riunion|meeting|"
    r"call\b|impegn|programma|schedul|fiss|prenot|organizz|segna|crea|aggiung|add\b|"
    r"book|spost|rimand|anticip|posticip|resched|move|cancell|elimin|annull|delete|"
    r"remove|cancel|rinomin|rename|modific|cambi|change)",
    re.IGNORECASE,
)

# Replies produced by calendar actions: a follow-up to them may be a calendar
# request even without hint words ("sì, quello di martedì").
_ACTION_REPLY_PREFIXES = ("📅", "✅")
_AMBIGUOUS_MARKER = "Quale intendi?"


def might_be_calendar_action(question: str, history: list[dict]) -> bool:
    """Cheap pre-check before spending an LLM call on intent classification."""
    if _CALENDAR_HINT.search(question):
        return True
    last_assistant = next(
        (m["content"] for m in reversed(history) if m.get("role") == "assistant"), ""
    )
    return last_assistant.startswith(_ACTION_REPLY_PREFIXES) or (
        _AMBIGUOUS_MARKER in last_assistant
    )


async def detect_and_execute_action(
    db: AsyncSession,
    user_id: uuid.UUID,
    question: str,
    history: list[dict],
) -> str | None:
    """Detect if the user's message requires an action. Execute it and return result text.

    Returns None if no action is needed (normal RAG query should proceed).
    Returns a string response if an action was executed.
    """
    from datetime import datetime, timedelta, timezone

    if not might_be_calendar_action(question, history):
        return None

    llm = get_llm_query_service()

    # Build detection prompt with recent history for context
    recent_history = history[-6:] if history else []
    history_text = ""
    if recent_history:
        history_text = "\nRecent conversation:\n"
        for msg in recent_history:
            role = "User" if msg["role"] == "user" else "Assistant"
            history_text += f"{role}: {msg['content'][:400]}\n"

    today = to_user_local_date(datetime.now(timezone.utc))
    tomorrow = today + timedelta(days=1)

    messages = [
        LLMMessage(
            role="system",
            content=DETECT_PROMPT.format(
                actions=AVAILABLE_ACTIONS,
                today=today.isoformat(),
                tomorrow=tomorrow.isoformat(),
            ),
        ),
        LLMMessage(
            role="user",
            content=f"{history_text}\nCurrent message: {question}",
        ),
    ]

    try:
        response = await llm.complete(messages, temperature=0.0)
        content = response.content.strip()

        # Parse JSON from response (handle markdown code blocks)
        if content.startswith("```"):
            content = content.split("\n", 1)[1].rsplit("```", 1)[0].strip()

        parsed = json.loads(content)
        action = parsed.get("action", "none")

        if action == "none":
            return None

        params = parsed.get("params", {})
        return await _execute_action(db, user_id, action, params)

    except (json.JSONDecodeError, Exception) as e:
        logger.warning(f"[ChatActions] Detection failed: {e}")
        return None


async def _resolve_event(
    db: AsyncSession, user_id: uuid.UUID, params: dict, verb: str
) -> tuple[dict | None, str | None]:
    """Find the event an update/delete refers to.

    Returns (event, None) when exactly one event matches, otherwise
    (None, reply) with a question or an explanation for the user.
    """
    if params.get("event_id"):
        return {"id": params["event_id"]}, None

    target = params.get("target") or {}
    summary = (target.get("summary") or "").strip()
    day = target.get("date")
    if not summary:
        return None, f"Quale evento vuoi {verb}? Dimmi il nome ed eventualmente il giorno."

    matches = await find_events(db, user_id, summary, day=day)
    if matches is None:
        return None, "Google Calendar non è connesso. Vai su Integrations per collegarlo."
    if not matches:
        period = f"per {_format_date_human(day)}" if day else "nei prossimi 14 giorni"
        return None, f"Non ho trovato \"{summary}\" {period}."
    if len(matches) > 1:
        lines = ["Ho trovato più eventi:"]
        lines.extend(_format_event_with_day(event) for event in matches[:5])
        lines.append(f"{_AMBIGUOUS_MARKER} Indicami il giorno o il nome completo.")
        return None, "\n".join(lines)
    return matches[0], None


async def _execute_action(
    db: AsyncSession, user_id: uuid.UUID, action: str, params: dict
) -> str:
    """Execute a detected action and return a human-readable response."""

    if action == "calendar_list":
        date_from = params.get("date_from")
        date_to = params.get("date_to")
        events = await list_events(db, user_id, date_from=date_from, date_to=date_to)
        if events is None:
            return "Google Calendar non è connesso. Vai su Integrations per collegarlo."
        if not events:
            period = _format_period(date_from, date_to)
            return f"Non hai eventi {period}."

        period = _format_period(date_from, date_to)
        lines = [f"📅 Ecco i tuoi eventi {period}:\n"]
        for ev in events:
            lines.append(_format_event(ev))
        return "\n".join(lines)

    elif action == "calendar_create":
        summary = params.get("summary")
        date = params.get("date")
        time = params.get("time")
        location = params.get("location")
        duration_minutes = _positive_int(params.get("duration_minutes"))

        if not summary or not date:
            return (
                "Non ho capito bene. Dimmi il nome dell'evento e la data "
                "(es: 'crea evento pranzo con Marco il 2026-08-01 alle 13:00')."
            )

        result = await create_event(
            db,
            user_id,
            summary=summary,
            date=date,
            time=time,
            location=location,
            duration_minutes=duration_minutes,
        )
        if result is None:
            return "Non sono riuscito a creare l'evento. Verifica che Google Calendar sia connesso."
        time_str = f" alle {time}" if time else ""
        loc_str = f" a {location}" if location else ""
        when = _format_date_human(date)
        return f"✅ Fatto! Ho creato **{summary}** per {when}{time_str}{loc_str}."

    elif action == "calendar_update":
        event, reply = await _resolve_event(db, user_id, params, "modificare")
        if event is None:
            return reply
        result = await update_event(
            db, user_id,
            event_id=event["id"],
            summary=params.get("summary"),
            date=params.get("date"),
            time=params.get("time"),
            location=params.get("location"),
            duration_minutes=_positive_int(params.get("duration_minutes")),
        )
        if result is None:
            return "Non sono riuscito a modificare l'evento."
        return f"✅ Evento **{result.get('summary', '')}** aggiornato."

    elif action == "calendar_delete":
        event, reply = await _resolve_event(db, user_id, params, "eliminare")
        if event is None:
            return reply
        success = await delete_event(db, user_id, event["id"])
        if success:
            name = event.get("summary")
            return f"✅ Evento **{name}** eliminato." if name else "✅ Evento eliminato."
        return "Non sono riuscito a eliminare l'evento."

    return "Azione non riconosciuta."


def _positive_int(value) -> int | None:
    """Duration from LLM params: a positive integer, or None (use the default)."""
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def _format_event(ev: dict) -> str:
    """Format a single calendar event with light markdown."""
    summary = ev.get("summary", "(senza titolo)")
    start_raw = ev.get("start", "")
    location = ev.get("location")

    # Parse time
    time_str = ""
    if "T" in start_raw:
        try:
            from datetime import datetime
            dt = datetime.fromisoformat(start_raw)
            time_str = dt.strftime("%H:%M")
        except (ValueError, TypeError):
            time_str = ""
    else:
        time_str = "tutto il giorno"

    line = f"• **{summary}**"
    if time_str:
        line += f" — {time_str}"
    if location:
        line += f"\n  📍 {location}"
    return line


def _format_event_with_day(ev: dict) -> str:
    """Event line including its day, used to disambiguate between matches."""
    day = (ev.get("start") or "")[:10]
    return f"{_format_event(ev)} ({_format_date_human(day)})" if day else _format_event(ev)


def _user_today():
    from datetime import datetime, timezone

    return to_user_local_date(datetime.now(timezone.utc))


def _format_period(date_from: str | None, date_to: str | None) -> str:
    """Format date range as natural period description."""
    from datetime import date, timedelta

    today = _user_today()
    tomorrow = today + timedelta(days=1)

    if not date_from:
        return "dei prossimi giorni"

    try:
        d_from = date.fromisoformat(date_from)
        d_to = date.fromisoformat(date_to) if date_to else d_from
    except (ValueError, TypeError):
        return "dei prossimi giorni"

    if d_from == today and d_to == today:
        return "di oggi"
    elif d_from == tomorrow and d_to == tomorrow:
        return "di domani"
    elif d_from == today and (d_to - today).days <= 7:
        return "di questa settimana"
    else:
        return f"dal {d_from.strftime('%d/%m')} al {d_to.strftime('%d/%m')}"


def _format_date_human(date_str: str) -> str:
    """Format a date string as human-readable Italian."""
    from datetime import date, timedelta

    today = _user_today()
    tomorrow = today + timedelta(days=1)

    try:
        d = date.fromisoformat(date_str)
    except (ValueError, TypeError):
        return date_str

    if d == today:
        return "oggi"
    elif d == tomorrow:
        return "domani"
    else:
        days_it = ["lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"]
        day_name = days_it[d.weekday()]
        return f"{day_name} {d.strftime('%d/%m')}"
