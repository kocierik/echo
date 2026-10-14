import json
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.policy import ToolTier, classify_call, is_people_key, toolkit_of
from app.actions.provider import ToolResult
from app.models.action_log import ActionLog

# Keys whose name contains one of these hold message bodies: never written to the audit log.
_REDACTED_KEY_PARTS = ("body", "text", "content", "message", "markdown", "html")
_VALUE_MAX = 80
_SUMMARY_MAX = 300


def _is_redacted(key: str) -> bool:
    lowered = key.lower()
    if lowered.endswith(("_id", "_ids")):  # message_id, thread_id: identifiers, not bodies
        return False
    return any(part in lowered for part in _REDACTED_KEY_PARTS)


def summarize_arguments(arguments: dict) -> str:
    """Compact, body-free description of tool arguments for the audit log."""
    parts = []
    for key, value in arguments.items():
        text = str(value)
        if _is_redacted(str(key)):
            shown = f"({len(text)} chars)"
        else:
            shown = text[:_VALUE_MAX]
        parts.append(f"{key}={shown}")
    return ", ".join(parts)[:_SUMMARY_MAX]


# --- Confirmation card text -------------------------------------------------------------

_VERBS = {
    "GMAIL_SEND_EMAIL": "Send email",
    "GMAIL_SEND_DRAFT": "Send email draft",
    "GMAIL_REPLY_TO_THREAD": "Reply to email",
    "GMAIL_FORWARD_MESSAGE": "Forward email",
    "GMAIL_CREATE_EMAIL_DRAFT": "Create email draft",
    "GMAIL_DELETE_MESSAGE": "Delete email",
    "GMAIL_DELETE_DRAFT": "Delete email draft",
    "SLACK_SEND_MESSAGE": "Send Slack message",
    "SLACK_CHAT_POST_MESSAGE": "Send Slack message",
    "SLACK_SENDS_A_MESSAGE_TO_A_SLACK_CHANNEL": "Send Slack message",
    "SLACK_UPDATES_A_SLACK_MESSAGE": "Update Slack message",
    "SLACK_DELETES_A_MESSAGE_FROM_A_CHAT": "Delete Slack message",
    "TELEGRAM_SEND_MESSAGE": "Send Telegram message",
    "TELEGRAM_EDIT_MESSAGE": "Update Telegram message",
    "TELEGRAM_DELETE_MESSAGE": "Delete Telegram message",
    "GOOGLECALENDAR_CREATE_EVENT": "Create event",
    "GOOGLECALENDAR_QUICK_ADD": "Create event",
    "GOOGLECALENDAR_UPDATE_EVENT": "Update event",
    "GOOGLECALENDAR_PATCH_EVENT": "Update event",
    "GOOGLECALENDAR_DELETE_EVENT": "Delete event",
    "TODOIST_CREATE_TASK": "Create task",
    "TODOIST_UPDATE_TASK": "Update task",
    "TODOIST_CLOSE_TASK": "Complete task",
    "TODOIST_DELETE_TASK": "Delete task",
    "NOTION_CREATE_NOTION_PAGE": "Create Notion page",
    "NOTION_UPDATE_PAGE": "Update Notion page",
    "NOTION_ARCHIVE_NOTION_PAGE": "Archive Notion page",
}
# Who receives it, in order of preference.
_TARGET_KEYS = (
    "to", "recipient_email", "recipient", "recipients", "to_email", "channel", "channel_id",
    "chat_id", "attendees",
)
# What it is about.
_TITLE_KEYS = ("subject", "summary", "title", "name")
_WHEN_KEYS = ("start_datetime", "start_time", "start", "due_string", "due_datetime", "due_date")
# The text that will be sent or written, first match shown as a preview.
_BODY_KEYS = (
    "body", "message_body", "text", "markdown_text", "message", "markdown", "html",
    "content", "description",
)
# Identifies what an update/delete/close touches when the call carries no readable title.
_ID_KEYS = ("event_id", "message_id", "task_id", "page_id", "draft_id", "id", "ts")
_CHANGING_WORDS = ("UPDATE", "PATCH", "EDIT", "DELETE", "REMOVE", "CLOSE", "ARCHIVE", "TRASH")
_PREVIEW_MAX = 200
_FIELD_MAX = 80
_PERSON_MAX = 100


def _display(value) -> str:
    if isinstance(value, list | tuple):
        items = [
            str(v.get("email") or v.get("name") or v) if isinstance(v, dict) else str(v)
            for v in value
        ]
        text = ", ".join(i for i in items if i)
    elif isinstance(value, dict):
        text = str(value.get("dateTime") or value.get("date") or value.get("email") or "")
    else:
        text = "" if value is None else str(value)
    text = " ".join(text.split())
    return text if len(text) <= _FIELD_MAX else text[:_FIELD_MAX] + "…"


def _people(value) -> list[str]:
    """Every person/address in a recipient argument, each capped, never dropped."""
    if isinstance(value, list | tuple | set):
        raw = [v.get("email") or v.get("name") or v if isinstance(v, dict) else v for v in value]
    elif isinstance(value, dict):
        raw = [value.get("email") or value.get("name") or ""]
    else:
        raw = [value]
    out = []
    for item in raw:
        text = " ".join(str("" if item is None or item is False else item).split())
        if text:
            out.append(text if len(text) <= _PERSON_MAX else text[:_PERSON_MAX] + "…")
    return out


def _is_empty(value) -> bool:
    if value is None or value is False:
        return True
    if isinstance(value, str):
        return not value.strip()
    if isinstance(value, list | tuple | dict | set):
        return len(value) == 0
    return False


def _argument_text(value) -> str:
    """One argument value on one line: lists joined with ", ", dicts as JSON."""

    def one(item) -> str:
        if isinstance(item, dict):
            if len(item) == 1 and ("email" in item or "name" in item):
                return str(next(iter(item.values())))
            return json.dumps(item, ensure_ascii=False, default=str)
        return "" if item is None else str(item)

    if isinstance(value, list | tuple | set):
        text = ", ".join(t for t in (one(v) for v in value) if t)
    else:
        text = one(value)
    return " ".join(text.split())


def _capped(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit] + "…"


def _fallback_shown(arguments: dict) -> set:
    """Keys whose whole value is visible in the summarize_arguments() fallback text."""
    shown = set()
    length = 0
    for key, value in arguments.items():
        text = str(value)
        length += len(f"{key}={text}") + (2 if length else 0)
        if length > _SUMMARY_MAX:
            break
        single_line = " ".join(text.split()) == text
        if not _is_redacted(str(key)) and len(text) <= _VALUE_MAX and single_line:
            shown.add(key)
    return shown


def _first(arguments: dict, keys: tuple[str, ...]) -> tuple[str | None, str]:
    for key in keys:
        if key in arguments:
            shown = _display(arguments[key])
            if shown:
                return key, shown
    return None, ""


def _verb(tool: str) -> str:
    upper = tool.upper()
    if upper in _VERBS:
        return _VERBS[upper]
    return " ".join(word.title() for word in tool.split("_") if word)


def pending_summary(tool: str, arguments: dict) -> str:
    """Readable text of a pending action for the confirmation card and chat.

    "Send email to ada@x.it: Budget" plus, on a second line, up to 200 characters of the
    text that would be sent. Unknown tools fall back to the slug words and the arguments.
    For a call that needs confirmation, every other non-empty argument follows as one
    "key: value" line: Confirm sends the stored arguments as they are, so none is hidden.
    """
    arguments = arguments if isinstance(arguments, dict) else {}
    is_task = toolkit_of(tool) == "todoist"
    title_keys = ("content", *_TITLE_KEYS) if is_task else _TITLE_KEYS
    body_keys = tuple(k for k in _BODY_KEYS if not (is_task and k == "content"))

    # Everyone the action reaches: the main target keys, then every other people key (cc, bcc,
    # extra_recipients, guests...) with its own label. Confirm sends the stored arguments as
    # they are, so nothing here may be hidden or truncated beyond a per-address cap.
    main: list[str] = []
    extras: list[str] = []
    target_key = None
    used = set()  # keys whose value the first line or the preview already shows
    for raw_key, value in arguments.items():
        key = str(raw_key)
        if key in _TARGET_KEYS:
            shown = _people(value)
            if shown:
                used.add(raw_key)
                target_key = target_key or key
                main += [p for p in shown if p not in main]
        elif is_people_key(key) and key.lower() != "send_updates":
            shown = _people(value)
            if shown:
                used.add(raw_key)
                label = " ".join(w for w in key.replace("-", "_").split("_") if w).capitalize()
                extras.append(f"{label}: {', '.join(shown)}")
    target = ", ".join(main)
    title_key, title = _first(arguments, title_keys)
    when_key, when = _first(arguments, _WHEN_KEYS)
    used.update(k for k in (title_key, when_key) if k is not None)

    ident = ""
    if not title and any(w in tool.upper() for w in _CHANGING_WORDS):
        for key in _ID_KEYS:
            shown = _people(arguments.get(key))
            if shown:
                ident = f"{key}={shown[0]}"
                if len(shown) == 1:
                    used.add(key)
                break

    preview = ""
    for key in body_keys:
        value = arguments.get(key)
        if isinstance(value, str) and value.strip():
            used.add(key)
            preview = _capped(" ".join(value.split()), _PREVIEW_MAX)
            break

    line = _verb(tool)
    if target:
        line += f" {'with' if target_key == 'attendees' else 'to'} {target}"
    for extra in extras:
        line += f" · {extra}"
    if title:
        line += f": {title}"
    if when:
        line += f" ({when})"
    if ident:
        line += f" ({ident})"
    elif not (target or extras or title or when or preview) and arguments:
        line += f" ({summarize_arguments(arguments)})"
        used.update(_fallback_shown(arguments))
    lines = [line, preview] if preview else [line]
    if classify_call(tool, arguments) != ToolTier.CONFIRM:
        return "\n".join(lines)

    lines[0] = " ".join(line.split())  # one line, whatever the arguments contain
    for key, value in arguments.items():
        if key in used or _is_empty(value):
            continue
        if _is_redacted(str(key)):  # another text that would be sent: a preview too
            text = value if isinstance(value, str) else _argument_text(value)
            shown = _capped(" ".join(text.split()), _PREVIEW_MAX)
        else:
            shown = _capped(_argument_text(value), _PERSON_MAX)
        lines.append(f"{' '.join(str(key).split())}: {shown}")
    return "\n".join(lines)


async def log_action(
    db: AsyncSession,
    user_id: uuid.UUID,
    source: str,
    tool: str,
    arguments: dict,
    result: ToolResult,
) -> ActionLog:
    """Add an audit row and flush; the caller owns the commit."""
    row = ActionLog(
        user_id=user_id,
        source=source,
        toolkit=toolkit_of(tool),
        tool=tool,
        arguments_summary=summarize_arguments(arguments),
        outcome="ok" if result.ok else ("unknown" if result.unknown else "error"),
        error=None if result.ok else result.error,
    )
    db.add(row)
    await db.flush()
    return row
