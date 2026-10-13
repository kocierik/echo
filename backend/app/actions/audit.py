import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.policy import toolkit_of
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
_PREVIEW_MAX = 200
_FIELD_MAX = 80


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
    """
    arguments = arguments if isinstance(arguments, dict) else {}
    is_task = toolkit_of(tool) == "todoist"
    title_keys = ("content", *_TITLE_KEYS) if is_task else _TITLE_KEYS
    body_keys = tuple(k for k in _BODY_KEYS if not (is_task and k == "content"))

    target_key, target = _first(arguments, _TARGET_KEYS)
    _, title = _first(arguments, title_keys)
    _, when = _first(arguments, _WHEN_KEYS)

    preview = ""
    for key in body_keys:
        value = arguments.get(key)
        if isinstance(value, str) and value.strip():
            preview = " ".join(value.split())
            if len(preview) > _PREVIEW_MAX:
                preview = preview[:_PREVIEW_MAX] + "…"
            break

    line = _verb(tool)
    if target:
        line += f" {'with' if target_key == 'attendees' else 'to'} {target}"
    if title:
        line += f": {title}"
    if when:
        line += f" ({when})"
    if not (target or title or when or preview) and arguments:
        line += f" ({summarize_arguments(arguments)})"
    return f"{line}\n{preview}" if preview else line


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
        outcome="ok" if result.ok else "error",
        error=None if result.ok else result.error,
    )
    db.add(row)
    await db.flush()
    return row
