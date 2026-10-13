import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.policy import toolkit_of
from app.actions.provider import ToolResult
from app.models.action_log import ActionLog

_REDACTED_KEYS = {"body", "message", "text", "content"}
_VALUE_MAX = 80
_SUMMARY_MAX = 300


def summarize_arguments(arguments: dict) -> str:
    """Compact, body-free description of tool arguments for the audit log."""
    parts = []
    for key, value in arguments.items():
        text = str(value)
        if key in _REDACTED_KEYS:
            shown = f"({len(text)} chars)"
        else:
            shown = text[:_VALUE_MAX]
        parts.append(f"{key}={shown}")
    return ", ".join(parts)[:_SUMMARY_MAX]


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
