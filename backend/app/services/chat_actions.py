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
from app.services.language import detect_language
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

# Fixed replies, in the language of the user's message (app default: English)
TEXT = {
    "en": {
        "not_connected": "Google Calendar is not connected. Connect it in Integrations.",
        "which_event": (
            "Which event do you want to {verb}? "
            "Tell me its name and, if you know it, the day."
        ),
        "verb_update": "change",
        "verb_delete": "delete",
        "not_found_day": 'I couldn\'t find "{summary}" on {day}.',
        "not_found": 'I couldn\'t find "{summary}" in the next 14 days.',
        "several": "I found several events:",
        "ambiguous": "Which one do you mean?",
        "ambiguous_hint": "Tell me the day or the full name.",
        "no_events": "You have no events {period}.",
        "events": "📅 Your events {period}:\n",
        "create_missing": (
            "I didn't quite get that. Tell me the event name and the date "
            "(e.g. 'create lunch with Marco on 2026-08-01 at 13:00')."
        ),
        "create_failed": "I couldn't create the event. Check that Google Calendar is connected.",
        "created": "✅ Done! I created **{summary}** for {when}{time}{location}.",
        "at_time": " at {time}",
        "at_location": " ({location})",
        "update_failed": "I couldn't update the event.",
        "updated": "✅ Updated **{summary}**.",
        "delete_failed": "I couldn't delete the event.",
        "deleted": "✅ Deleted **{summary}**.",
        "deleted_unnamed": "✅ Event deleted.",
        "unknown_action": "I don't know how to do that yet.",
        "untitled": "(untitled)",
        "all_day": "all day",
        "today": "today",
        "tomorrow": "tomorrow",
        "period_today": "for today",
        "period_tomorrow": "for tomorrow",
        "period_week": "for this week",
        "period_next_days": "for the next few days",
        "period_range": "from {start} to {end}",
        "weekdays": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
    },
    "it": {
        "not_connected": "Google Calendar non è connesso. Vai su Integrations per collegarlo.",
        "which_event": "Quale evento vuoi {verb}? Dimmi il nome ed eventualmente il giorno.",
        "verb_update": "modificare",
        "verb_delete": "eliminare",
        "not_found_day": 'Non ho trovato "{summary}" per {day}.',
        "not_found": 'Non ho trovato "{summary}" nei prossimi 14 giorni.',
        "several": "Ho trovato più eventi:",
        "ambiguous": "Quale intendi?",
        "ambiguous_hint": "Indicami il giorno o il nome completo.",
        "no_events": "Non hai eventi {period}.",
        "events": "📅 Ecco i tuoi eventi {period}:\n",
        "create_missing": (
            "Non ho capito bene. Dimmi il nome dell'evento e la data "
            "(es: 'crea evento pranzo con Marco il 2026-08-01 alle 13:00')."
        ),
        "create_failed": (
            "Non sono riuscito a creare l'evento. Verifica che Google Calendar sia connesso."
        ),
        "created": "✅ Fatto! Ho creato **{summary}** per {when}{time}{location}.",
        "at_time": " alle {time}",
        "at_location": " a {location}",
        "update_failed": "Non sono riuscito a modificare l'evento.",
        "updated": "✅ Evento **{summary}** aggiornato.",
        "delete_failed": "Non sono riuscito a eliminare l'evento.",
        "deleted": "✅ Evento **{summary}** eliminato.",
        "deleted_unnamed": "✅ Evento eliminato.",
        "unknown_action": "Azione non riconosciuta.",
        "untitled": "(senza titolo)",
        "all_day": "tutto il giorno",
        "today": "oggi",
        "tomorrow": "domani",
        "period_today": "di oggi",
        "period_tomorrow": "di domani",
        "period_week": "di questa settimana",
        "period_next_days": "dei prossimi giorni",
        "period_range": "dal {start} al {end}",
        "weekdays": ["lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"],
    },
}

_AMBIGUOUS_MARKERS = tuple(texts["ambiguous"] for texts in TEXT.values())


def _t(language: str, key: str, **values) -> str:
    texts = TEXT.get(language, TEXT["en"])
    return texts[key].format(**values) if values else texts[key]


def might_be_calendar_action(question: str, history: list[dict]) -> bool:
    """Cheap pre-check before spending an LLM call on intent classification."""
    if _CALENDAR_HINT.search(question):
        return True
    last_assistant = next(
        (m["content"] for m in reversed(history) if m.get("role") == "assistant"), ""
    )
    return last_assistant.startswith(_ACTION_REPLY_PREFIXES) or any(
        marker in last_assistant for marker in _AMBIGUOUS_MARKERS
    )


async def detect_and_execute_action(
    db: AsyncSession,
    user_id: uuid.UUID,
    question: str,
    history: list[dict],
) -> str | None:
    """Detect if the user's message requires an action. Execute it and return result text.

    Returns None if no action is needed (normal RAG query should proceed).
    Returns a string response, in the language of the question, if an action ran.
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
        return await _execute_action(
            db, user_id, action, params, language=detect_language(question)
        )

    except (json.JSONDecodeError, Exception) as e:
        logger.warning(f"[ChatActions] Detection failed: {e}")
        return None


async def _resolve_event(
    db: AsyncSession, user_id: uuid.UUID, params: dict, action: str, language: str = "en"
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
        verb = _t(language, "verb_update" if action == "update" else "verb_delete")
        return None, _t(language, "which_event", verb=verb)

    matches = await find_events(db, user_id, summary, day=day)
    if matches is None:
        return None, _t(language, "not_connected")
    if not matches:
        if day:
            return None, _t(
                language, "not_found_day", summary=summary, day=_format_date_human(day, language)
            )
        return None, _t(language, "not_found", summary=summary)
    if len(matches) > 1:
        lines = [_t(language, "several")]
        lines.extend(_format_event_with_day(event, language) for event in matches[:5])
        lines.append(f"{_t(language, 'ambiguous')} {_t(language, 'ambiguous_hint')}")
        return None, "\n".join(lines)
    return matches[0], None


async def _execute_action(
    db: AsyncSession, user_id: uuid.UUID, action: str, params: dict, language: str = "en"
) -> str:
    """Execute a detected action and return a human-readable response."""

    if action == "calendar_list":
        date_from = params.get("date_from")
        date_to = params.get("date_to")
        events = await list_events(db, user_id, date_from=date_from, date_to=date_to)
        if events is None:
            return _t(language, "not_connected")
        period = _format_period(date_from, date_to, language)
        if not events:
            return _t(language, "no_events", period=period)

        lines = [_t(language, "events", period=period)]
        for ev in events:
            lines.append(_format_event(ev, language))
        return "\n".join(lines)

    elif action == "calendar_create":
        summary = params.get("summary")
        date = params.get("date")
        time = params.get("time")
        location = params.get("location")
        duration_minutes = _positive_int(params.get("duration_minutes"))

        if not summary or not date:
            return _t(language, "create_missing")

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
            return _t(language, "create_failed")
        return _t(
            language,
            "created",
            summary=summary,
            when=_format_date_human(date, language),
            time=_t(language, "at_time", time=time) if time else "",
            location=_t(language, "at_location", location=location) if location else "",
        )

    elif action == "calendar_update":
        event, reply = await _resolve_event(db, user_id, params, "update", language)
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
            return _t(language, "update_failed")
        return _t(language, "updated", summary=result.get("summary", ""))

    elif action == "calendar_delete":
        event, reply = await _resolve_event(db, user_id, params, "delete", language)
        if event is None:
            return reply
        success = await delete_event(db, user_id, event["id"])
        if not success:
            return _t(language, "delete_failed")
        name = event.get("summary")
        return _t(language, "deleted", summary=name) if name else _t(language, "deleted_unnamed")

    return _t(language, "unknown_action")


def _positive_int(value) -> int | None:
    """Duration from LLM params: a positive integer, or None (use the default)."""
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def _format_event(ev: dict, language: str = "en") -> str:
    """Format a single calendar event with light markdown."""
    summary = ev.get("summary") or _t(language, "untitled")
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
        time_str = _t(language, "all_day")

    line = f"• **{summary}**"
    if time_str:
        line += f" — {time_str}"
    if location:
        line += f"\n  📍 {location}"
    return line


def _format_event_with_day(ev: dict, language: str = "en") -> str:
    """Event line including its day, used to disambiguate between matches."""
    day = (ev.get("start") or "")[:10]
    line = _format_event(ev, language)
    return f"{line} ({_format_date_human(day, language)})" if day else line


def _user_today():
    from datetime import datetime, timezone

    return to_user_local_date(datetime.now(timezone.utc))


def _format_period(date_from: str | None, date_to: str | None, language: str = "en") -> str:
    """Format date range as natural period description."""
    from datetime import date, timedelta

    today = _user_today()
    tomorrow = today + timedelta(days=1)

    if not date_from:
        return _t(language, "period_next_days")

    try:
        d_from = date.fromisoformat(date_from)
        d_to = date.fromisoformat(date_to) if date_to else d_from
    except (ValueError, TypeError):
        return _t(language, "period_next_days")

    if d_from == today and d_to == today:
        return _t(language, "period_today")
    elif d_from == tomorrow and d_to == tomorrow:
        return _t(language, "period_tomorrow")
    elif d_from == today and (d_to - today).days <= 7:
        return _t(language, "period_week")
    return _t(
        language, "period_range", start=d_from.strftime("%d/%m"), end=d_to.strftime("%d/%m")
    )


def _format_date_human(date_str: str, language: str = "en") -> str:
    """Format a date string as a human-readable day ("today", "Tuesday 20/10")."""
    from datetime import date, timedelta

    today = _user_today()
    tomorrow = today + timedelta(days=1)

    try:
        d = date.fromisoformat(date_str)
    except (ValueError, TypeError):
        return date_str

    if d == today:
        return _t(language, "today")
    elif d == tomorrow:
        return _t(language, "tomorrow")
    day_name = TEXT.get(language, TEXT["en"])["weekdays"][d.weekday()]
    return f"{day_name} {d.strftime('%d/%m')}"
