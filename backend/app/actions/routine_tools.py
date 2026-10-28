"""The action agent's own tools for routines: create, list and delete them.

They run here, in-process (no connected app, no confirmation: a routine only concerns the
user, who sees and stops it in Profile → Routines). Results are what the model reads.
"""

import uuid
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.provider import ToolResult
from app.core.config import settings
from app.models.routine import Routine
from app.services.plans import user_plan
from app.services.routine_results import MODES
from app.services.routines import describe_schedule, next_run, validate_schedule

CREATE = "ECHO_CREATE_ROUTINE"
LIST = "ECHO_LIST_ROUTINES"
DELETE = "ECHO_DELETE_ROUTINE"

ROUTINE_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": CREATE,
            "description": (
                "Make Echo do something on its own at a regular time (at most once a day) "
                "and tell the user the result as a notification: 'every morning at 7 tell me "
                "the weather in Milan'. Only when the user gave both what and when."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "instruction": {
                        "type": "string",
                        "description": (
                            "What to do each time, in the user's words and language, with "
                            "every detail it needs (the city, the app, ...), without the time."
                        ),
                    },
                    "kind": {"type": "string", "enum": ["daily", "weekdays", "weekly", "monthly"]},
                    "time": {"type": "string", "description": "Local time, HH:MM, 24-hour."},
                    "days": {
                        "type": "array",
                        "items": {"type": "integer", "minimum": 1, "maximum": 7},
                        "description": "weekly only: ISO days, 1 = Monday ... 7 = Sunday.",
                    },
                    "day_of_month": {
                        "type": "integer", "minimum": 1, "maximum": 28,
                        "description": "monthly only.",
                    },
                    "mode": {
                        "type": "string",
                        "enum": list(MODES),
                        "description": (
                            "When it speaks. only_if: the request has a condition ('se piove', "
                            "'if it is below zero'): it tells the user only when it holds. "
                            "only_new: the user wants what is new ('new', 'nuove', 'se ci sono "
                            "novità', job openings, listings): it tells only what it did not "
                            "report before. always (default): it reports every time. Keep the "
                            "condition in the instruction. Say to the user in their words "
                            "when it will speak."
                        ),
                    },
                },
                "required": ["instruction", "kind", "time"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": LIST,
            "description": "The user's routines, with their ids, schedules and next runs.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": DELETE,
            "description": "Delete one of the user's routines (list them first for its id).",
            "parameters": {
                "type": "object",
                "properties": {"routine_id": {"type": "string"}},
                "required": ["routine_id"],
            },
        },
    },
]

ROUTINE_TOOL_NAMES = frozenset({CREATE, LIST, DELETE})


def _local(when: datetime, tz: str) -> str:
    return when.astimezone(ZoneInfo(tz)).strftime("%A %Y-%m-%d %H:%M")


# What each mode means, for the model to say in the user's language
MODE_TEXT = {
    "always": "always tells you",
    "only_if": "tells you only if the condition holds",
    "only_new": "tells you only what is new",
}


def _described(routine: Routine) -> dict:
    return {
        "id": str(routine.id),
        "instruction": routine.instruction,
        "schedule": describe_schedule(routine.schedule),
        "mode": routine.mode,
        "mode_text": MODE_TEXT.get(routine.mode, MODE_TEXT["always"]),
        "active": routine.active,
        "next_run": _local(routine.next_run_at, routine.timezone),
    }


async def run_routine_tool(
    db: AsyncSession, user_id: uuid.UUID, source: str, name: str, arguments: dict
) -> ToolResult:
    """Run one routine tool; the caller logs it and commits."""
    if name == CREATE:
        instruction = str(arguments.get("instruction") or "").strip()
        if not instruction:
            return ToolResult(ok=False, error="instruction is required")
        try:
            schedule = validate_schedule({
                key: arguments[key]
                for key in ("kind", "time", "days", "day_of_month")
                if key in arguments
            })
        except ValueError as exc:
            return ToolResult(ok=False, error=str(exc))
        mode = arguments.get("mode") or "always"
        if mode not in MODES:
            return ToolResult(ok=False, error="mode must be always, only_if or only_new")
        count = await db.scalar(
            select(func.count()).select_from(Routine).where(Routine.user_id == user_id)
        )
        # As many as the plan has (services/plans.py); a lowered plan keeps the ones made
        limit = (await user_plan(db, user_id)).routines
        if count >= limit:
            return ToolResult(
                ok=False,
                error=(
                    f"At most {limit} routines on your plan. "
                    "Delete one first (Profile → Routines)."
                ),
            )
        tz = settings.user_timezone
        routine = Routine(
            id=uuid.uuid4(),
            user_id=user_id,
            instruction=instruction,
            schedule=schedule,
            timezone=tz,
            active=True,
            next_run_at=next_run(schedule, tz, datetime.now(timezone.utc)),
            source=source if source in ("chat", "voice") else "chat",
            mode=mode,
        )
        db.add(routine)
        await db.flush()
        return ToolResult(ok=True, data={"created": _described(routine)})

    if name == LIST:
        routines = await db.scalars(
            select(Routine).where(Routine.user_id == user_id).order_by(Routine.created_at)
        )
        return ToolResult(ok=True, data={"routines": [_described(r) for r in routines]})

    if name == DELETE:
        try:
            routine_id = uuid.UUID(str(arguments.get("routine_id")))
        except ValueError:
            return ToolResult(ok=False, error="Routine not found")
        routine = await db.get(Routine, routine_id)
        if routine is None or routine.user_id != user_id:
            return ToolResult(ok=False, error="Routine not found")
        await db.delete(routine)
        await db.flush()
        return ToolResult(ok=True, data={"deleted": routine.instruction})

    return ToolResult(ok=False, error=f"Unknown tool: {name}")
