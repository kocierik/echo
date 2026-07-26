"""Chat action detection — detect and execute user intents (calendar, tasks, etc.)."""

import json
import logging
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.services.calendar_service import create_event, delete_event, list_events, update_event
from app.services.llm_base import LLMMessage
from app.services.llm_openai import get_llm_query_service

logger = logging.getLogger(__name__)

# Actions the chat can perform
AVAILABLE_ACTIONS = """
Available actions you can take:
1. calendar_list — List events for a specific period (params: date_from YYYY-MM-DD, date_to YYYY-MM-DD)
2. calendar_create — Create an event (params: summary, date YYYY-MM-DD, time HH:MM optional, location optional)
3. calendar_update — Update an event (params: event_id, summary, date, time, location — all optional except event_id)
4. calendar_delete — Delete an event (params: event_id)
5. none — No action needed, just answer the question
"""

DETECT_PROMPT = """You are an intent classifier for a personal assistant chat.
The user may ask questions about their memory OR request actions (create/read/modify/delete calendar events).

Determine if the user's message requires an ACTION or is just a QUESTION about their past conversations/memory.

{actions}

Respond with ONLY a JSON object:
- If it's a question about memory/past conversations: {{"action": "none"}}
- If it's a calendar list request: {{"action": "calendar_list", "params": {{"date_from": "YYYY-MM-DD", "date_to": "YYYY-MM-DD"}}}}
  - "domani" = tomorrow's date for both date_from and date_to
  - "questa settimana" = today to end of week
  - "prossima settimana" = next monday to next sunday
- If it's a calendar create request: {{"action": "calendar_create", "params": {{"summary": "...", "date": "YYYY-MM-DD", "time": "HH:MM", "location": "..."}}}}
- If it's a calendar update: {{"action": "calendar_update", "params": {{"event_id": "...", "summary": "..."}}}}
- If it's a calendar delete: {{"action": "calendar_delete", "params": {{"event_id": "..."}}}}

Today's date: {today}
Tomorrow's date: {tomorrow}

Only return the JSON, nothing else."""


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
    from datetime import date, timedelta

    llm = get_llm_query_service()

    # Build detection prompt with recent history for context
    recent_history = history[-6:] if history else []
    history_text = ""
    if recent_history:
        history_text = "\nRecent conversation:\n"
        for msg in recent_history:
            role = "User" if msg["role"] == "user" else "Assistant"
            history_text += f"{role}: {msg['content'][:200]}\n"

    today = date.today()
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
        lines = [f"Ecco i tuoi eventi {period}:\n"]
        for ev in events:
            lines.append(_format_event(ev))
        return "\n".join(lines)

    elif action == "calendar_create":
        summary = params.get("summary")
        date = params.get("date")
        time = params.get("time")
        location = params.get("location")

        if not summary or not date:
            return "Non ho capito bene. Dimmi il nome dell'evento e la data (es: 'crea evento pranzo con Marco il 2026-08-01 alle 13:00')."

        result = await create_event(
            db, user_id, summary=summary, date=date, time=time, location=location
        )
        if result is None:
            return "Non sono riuscito a creare l'evento. Verifica che Google Calendar sia connesso."
        time_str = f" alle {time}" if time else ""
        loc_str = f" a {location}" if location else ""
        return f"Fatto! Ho creato \"{summary}\" per il {_format_date_human(date)}{time_str}{loc_str}."

    elif action == "calendar_update":
        event_id = params.get("event_id")
        if not event_id:
            return "Non ho trovato l'evento da modificare. Prova a specificare quale evento vuoi cambiare."
        result = await update_event(
            db, user_id,
            event_id=event_id,
            summary=params.get("summary"),
            date=params.get("date"),
            time=params.get("time"),
            location=params.get("location"),
        )
        if result is None:
            return "Non sono riuscito a modificare l'evento."
        return f"Fatto! Ho aggiornato l'evento \"{result.get('summary', '')}\"."

    elif action == "calendar_delete":
        event_id = params.get("event_id")
        if not event_id:
            return "Non ho capito quale evento eliminare."
        success = await delete_event(db, user_id, event_id)
        if success:
            return "Fatto! Evento eliminato dal calendario."
        return "Non sono riuscito a eliminare l'evento."

    return "Azione non riconosciuta."


def _format_event(ev: dict) -> str:
    """Format a single calendar event in natural language."""
    summary = ev.get("summary", "(senza titolo)")
    start_raw = ev.get("start", "")
    location = ev.get("location")

    # Parse time
    time_str = ""
    if "T" in start_raw:
        try:
            from datetime import datetime
            dt = datetime.fromisoformat(start_raw)
            time_str = f"alle {dt.strftime('%H:%M')}"
        except (ValueError, TypeError):
            time_str = ""
    else:
        time_str = "tutto il giorno"

    parts = [f"  • {summary}"]
    if time_str:
        parts.append(time_str)
    if location:
        parts.append(f"a {location}")

    return " — ".join(parts)


def _format_period(date_from: str | None, date_to: str | None) -> str:
    """Format date range as natural period description."""
    from datetime import date, timedelta

    today = date.today()
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

    today = date.today()
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
