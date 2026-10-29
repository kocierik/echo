"""An assistant's notes tool (services/assistants.py), offered only in its chat: add a line
when the user tells it something worth keeping for its topic, remove one. Full notes make
room by dropping their oldest lines: a chat never stops on them.
"""

import re

from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.provider import ToolResult
from app.models.assistant import Assistant
from app.services.assistants import MAX_NOTES
from app.services.user_facts import normalize

UPDATE_NOTES = "ECHO_UPDATE_ASSISTANT_NOTES"
MAX_LINE = 300

ASSISTANT_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": UPDATE_NOTES,
            "description": (
                "Add a line to this assistant's notes when the user tells you something "
                "worth keeping for its topic (a meal, a night's sleep, a project's deadline), "
                "or remove one that is no longer true. One short line, in the user's language."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["add", "remove"]},
                    "line": {
                        "type": "string",
                        "description": "The line to add, or the words of the line to remove.",
                    },
                },
                "required": ["action", "line"],
            },
        },
    },
]

ASSISTANT_TOOL_NAMES = frozenset({UPDATE_NOTES})


def _lines(notes: str) -> list[str]:
    return [line for line in notes.splitlines() if line.strip()]


async def run_assistant_tool(
    db: AsyncSession, assistant: Assistant, name: str, arguments: dict
) -> ToolResult:
    """Run the notes tool; the caller logs it and commits."""
    if name != UPDATE_NOTES:
        return ToolResult(ok=False, error=f"Unknown tool: {name}")
    line = " ".join(str(arguments.get("line") or "").split())[:MAX_LINE]
    if not line:
        return ToolResult(ok=False, error="line is required")
    lines = _lines(assistant.notes)
    if arguments.get("action") == "remove":
        wanted = normalize(line.removeprefix("- "))
        about = [
            existing for existing in lines
            if re.search(rf"\b{re.escape(wanted)}\b", normalize(existing))
        ]
        if len(about) != 1:
            return ToolResult(
                ok=False,
                error="No such line" if not about else "Several lines match: say which one",
            )
        lines.remove(about[0])
        assistant.notes = "\n".join(lines)
        return ToolResult(ok=True, data={"removed": about[0]})
    lines.append(line if line.startswith("- ") else f"- {line}")
    # The oldest lines make room
    while len("\n".join(lines)) > MAX_NOTES and len(lines) > 1:
        lines.pop(0)
    assistant.notes = "\n".join(lines)
    return ToolResult(ok=True, data={"added": lines[-1]})
