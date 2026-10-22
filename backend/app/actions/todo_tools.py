"""The action agent's own to-do tool: Echo's to-do list (Today → To do), for a to-do the
user asks for without naming an app ("Ehi Echo, segnami di comprare il latte").

To-dos no longer come from conversations, except the user's promises
(services/analysis_pipeline.py): this is how the others are made.
"""

import uuid
from datetime import date

from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.provider import ToolResult
from app.models.entity import Entity

CREATE = "ECHO_CREATE_TASK"

TODO_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": CREATE,
            "description": (
                "Add a to-do to Echo's own list (shown in the app's Today). For a to-do or "
                "a reminder the user asks for when no app is named and no phone Reminders "
                "fit."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "The to-do as an action, in the user's language.",
                    },
                    "due_date": {
                        "type": "string",
                        "description": "YYYY-MM-DD, only when the user gave a day.",
                    },
                    "notes": {"type": "string", "description": "Details, when there are."},
                },
                "required": ["name"],
            },
        },
    },
]

TODO_TOOL_NAMES = frozenset({CREATE})


async def run_todo_tool(
    db: AsyncSession, user_id: uuid.UUID, name: str, arguments: dict
) -> ToolResult:
    """Run the to-do tool; the caller logs it and commits."""
    if name != CREATE:
        return ToolResult(ok=False, error=f"Unknown tool: {name}")
    title = str(arguments.get("name") or "").strip()
    if not title:
        return ToolResult(ok=False, error="name is required")
    metadata: dict = {"done": False, "asked": True}
    due = arguments.get("due_date")
    if due:
        try:
            metadata["due_date"] = date.fromisoformat(str(due)).isoformat()
        except ValueError:
            return ToolResult(ok=False, error="due_date must be YYYY-MM-DD")
    notes = str(arguments.get("notes") or "").strip() or None
    task = Entity(
        id=uuid.uuid4(), user_id=user_id, entity_type="task", name=title, content=notes,
        metadata_=metadata,
    )
    db.add(task)
    await db.flush()
    return ToolResult(ok=True, data={"added": title, "due_date": metadata.get("due_date")})
