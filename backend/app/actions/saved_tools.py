"""The action agent's own tools for Saved: save, update, find, sum and remove things the
user asks Echo to keep ("ricordati dove ho parcheggiato", "salvami questo vino", "quanto
ho speso questa settimana?").

They run here, in-process, like the routine and to-do tools (no app, no confirmation: a
saved thing only concerns the user, who sees and removes it in Today → Saved). The place
is read from the phone only when the save asks for it (services/phone_location.py).
"""

import logging
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.actions.provider import ToolResult
from app.core.timezone import local_day_bounds
from app.models.photo import Photo
from app.models.saved import SavedItem, SavedList
from app.services import saved
from app.services.phone_location import LOCATION_WAIT_S, ask_phone_location

logger = logging.getLogger(__name__)

SAVE = "ECHO_SAVE_ITEM"
UPDATE = "ECHO_UPDATE_ITEM"
FIND = "ECHO_FIND_ITEMS"
SUM = "ECHO_SUM_ITEMS"
REMOVE = "ECHO_REMOVE_ITEM"

# "This photo" is the thread's last one, taken this recently
PHOTO_WINDOW = timedelta(minutes=10)
# A place is read only for a request said this recently: one that reached Echo later (the
# wearable was away from the phone) would get where the phone is now, not where it was said
PLACE_FRESH = timedelta(minutes=3)
MAX_FOUND = 10
MAX_PHOTO_TEXT = 600

# Told to the model when the place could not be read
_PLACE_NOT_SAVED = {
    "no_phone": "not saved: the phone did not answer (is the Echo app running?)",
    "timeout": "not saved: the phone did not answer in time",
    "background": (
        "not saved yet: the Echo app was in the background; the user is asked on the phone "
        "to open the Echo app to add it"
    ),
    "denied": "not saved: Echo may not use the phone's location (the phone's Settings)",
    "unavailable": "not saved: the phone could not tell where it is",
}

_PLACE_TOO_LATE = (
    "not saved: the user said this {minutes} minutes ago and it reached Echo only now (the "
    "wearable was away from the phone), so where the phone is now may not be the place; "
    "tell them to ask again when they are there"
)

_THING_PROPERTIES = {
    "details": {
        "type": "string",
        "description": "What to remember about it, in the user's words and language "
        "(where it is, who recommended it, why).",
    },
    "fields": {
        "type": "object",
        "description": "Free values worth finding or summing: amount (a number) and "
        "currency (EUR, USD) of a receipt, shop, vintage, author, level and column of a "
        "parking...",
    },
    "people": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Names of the people the user says were there or recommended it.",
    },
    "with_place": {
        "type": "boolean",
        "description": "Read the phone's position now and keep it: only when the user asks "
        "to remember the place itself (where they parked, 'save this place').",
    },
    "with_photo": {
        "type": "boolean",
        "description": "Attach the photo just taken in this conversation.",
    },
}


def _tool(name: str, description: str, properties: dict, required: list[str]) -> dict:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {"type": "object", "properties": properties, "required": required},
        },
    }


_PERIOD = {
    "date_from": {"type": "string", "description": "YYYY-MM-DD, the first day."},
    "date_to": {"type": "string", "description": "YYYY-MM-DD, the last day (included)."},
}

SAVED_TOOLS = [
    _tool(
        SAVE,
        "Keep something the user wants to find again in Saved (Today → Saved), in a list: "
        "where the car is parked, where something was put, a wine, a book, a receipt. A "
        "thing with the same title in the same list is updated.",
        {
            "list": {
                "type": "string",
                "description": "The list: one of the user's lists by its exact name when it "
                "fits, else a new short plural name in the user's language.",
            },
            "title": {"type": "string", "description": "What it is, short."},
            **_THING_PROPERTIES,
            "latest_only": {
                "type": "boolean",
                "description": "New list only: keep only its latest thing (the car).",
            },
            "keep_days": {
                "type": "integer", "minimum": 1,
                "description": "New list only: delete its things after these days.",
            },
        },
        ["list", "title"],
    ),
    _tool(
        UPDATE,
        "Change a saved thing (find it first for its id): new details or fields, a photo, "
        "the place, or another list (move).",
        {
            "item_id": {"type": "string"},
            "title": {"type": "string"},
            **_THING_PROPERTIES,
            "list": {"type": "string", "description": "Move it to this list."},
        },
        ["item_id"],
    ),
    _tool(
        FIND,
        "Find saved things by words, list and period: where something is, what it was. "
        "Without arguments, the latest ones.",
        {
            "query": {"type": "string", "description": "Words of what is looked for."},
            "list": {"type": "string"},
            **_PERIOD,
        },
        [],
    ),
    _tool(
        SUM,
        "Add up a numeric field (amount by default) of saved things over a list and a "
        "period: 'how much did I spend this week'.",
        {
            "list": {"type": "string"},
            "field": {"type": "string", "description": "The field to add up; amount."},
            **_PERIOD,
        },
        [],
    ),
    _tool(
        REMOVE,
        "Remove a saved thing (find it first for its id): found again, no longer needed.",
        {"item_id": {"type": "string"}},
        ["item_id"],
    ),
]

SAVED_TOOL_NAMES = frozenset({SAVE, UPDATE, FIND, SUM, REMOVE})


@dataclass
class SavedContext:
    """What a save knows besides the model's arguments: the phone to ask for the place,
    the thread (its last photo), the voice request's segment and conversation (the
    moment), the photo the request took and what it shows."""

    redis_client: object | None = None
    chat_session_id: uuid.UUID | None = None
    segment_id: uuid.UUID | None = None
    conversation_id: uuid.UUID | None = None
    photo_id: uuid.UUID | None = None
    photo_text: str | None = None
    # None: the configured one
    embedding_service: object | None = None
    # When a voice request was said (its segment); None: now (typed in Ask)
    said_at: datetime | None = None

    def embedder(self):
        if self.embedding_service is None:
            from app.services.embedding_openai import get_embedding_service

            self.embedding_service = get_embedding_service()
        return self.embedding_service


def _day(value, end: bool = False) -> datetime | None:
    if not value:
        return None
    day = date.fromisoformat(str(value)[:10])
    return local_day_bounds(day)[1 if end else 0]


def _text(arguments: dict, key: str) -> str | None:
    value = arguments.get(key)
    return value.strip() or None if isinstance(value, str) else None


def _fields(arguments: dict) -> dict | None:
    fields = arguments.get("fields")
    return fields if isinstance(fields, dict) else None


def _names(arguments: dict) -> list[str]:
    people = arguments.get("people")
    if isinstance(people, str):
        people = [people]
    return [str(p) for p in people] if isinstance(people, list) else []


async def _recent_photo(
    db: AsyncSession, user_id: uuid.UUID, context: SavedContext
) -> Photo | None:
    """The photo the request is about: the one it took, else the thread's last one."""
    if context.photo_id is not None:
        return await db.get(Photo, context.photo_id)
    if context.chat_session_id is None:
        return None
    return (
        await db.execute(
            select(Photo)
            .where(Photo.user_id == user_id)
            .where(Photo.chat_session_id == context.chat_session_id)
            .where(Photo.status == "done")
            .where(Photo.created_at >= datetime.now(timezone.utc) - PHOTO_WINDOW)
            .order_by(Photo.created_at.desc())
            .limit(1)
        )
    ).scalar_one_or_none()


async def _own_item(db: AsyncSession, user_id: uuid.UUID, arguments: dict) -> SavedItem | None:
    try:
        item_id = uuid.UUID(str(arguments.get("item_id")))
    except ValueError:
        return None
    item = await db.get(SavedItem, item_id)
    return item if item is not None and item.user_id == user_id else None


async def _photo_texts(db: AsyncSession, items: list[SavedItem]) -> dict:
    ids = [i.photo_id for i in items if i.photo_id is not None]
    if not ids:
        return {}
    rows = await db.execute(select(Photo.id, Photo.description).where(Photo.id.in_(ids)))
    return {row.id: (row.description or "")[:MAX_PHOTO_TEXT] or None for row in rows}


async def _with_place(
    db: AsyncSession, user_id: uuid.UUID, item: SavedItem, context: SavedContext, data: dict
) -> None:
    """Ask the phone where it is and keep it on the thing; say so when it could not."""
    if context.said_at is not None:
        late = datetime.now(timezone.utc) - context.said_at
        if late > PLACE_FRESH:
            data["place"] = _PLACE_TOO_LATE.format(minutes=int(late.total_seconds() // 60))
            return
    answer = await ask_phone_location(
        context.redis_client, user_id, item_id=str(item.id), wait_s=LOCATION_WAIT_S
    )
    if answer.place is not None:
        await saved.update_item(db, item, place=answer.place)
        data["place"] = answer.place.get("address") or "saved (no address)"
    else:
        data["place"] = _PLACE_NOT_SAVED.get(answer.error, _PLACE_NOT_SAVED["unavailable"])


async def _photo_for(
    db: AsyncSession, user_id: uuid.UUID, arguments: dict, context: SavedContext, data: dict
) -> Photo | None:
    if context.photo_id is None and not arguments.get("with_photo"):
        return None
    photo = await _recent_photo(db, user_id, context)
    if photo is None:
        data["photo"] = "no photo in the last 10 minutes: saved without one"
    return photo


async def run_saved_tool(
    db: AsyncSession,
    user_id: uuid.UUID,
    source: str,
    name: str,
    arguments: dict,
    context: SavedContext,
    request: str,
) -> ToolResult:
    """Run one Saved tool; the caller logs it and commits."""
    try:
        if name == SAVE:
            return await _save(db, user_id, source, arguments, context, request)
        if name == UPDATE:
            return await _update(db, user_id, arguments, context)
        if name == FIND:
            items = await saved.find_items(
                db, user_id, query=_text(arguments, "query"), list_name=_text(arguments, "list"),
                date_from=_day(arguments.get("date_from")),
                date_to=_day(arguments.get("date_to"), end=True),
                limit=MAX_FOUND, embedding_service=context.embedder(),
            )
            texts = await _photo_texts(db, items)
            return ToolResult(ok=True, data={
                "found": [saved.describe_item(i, photo_text=texts.get(i.photo_id)) for i in items]
            })
        if name == SUM:
            total = await saved.sum_items(
                db, user_id, list_name=_text(arguments, "list"),
                field=_text(arguments, "field") or "amount",
                date_from=_day(arguments.get("date_from")),
                date_to=_day(arguments.get("date_to"), end=True),
            )
            return ToolResult(ok=True, data=total)
        if name == REMOVE:
            item = await _own_item(db, user_id, arguments)
            if item is None:
                return ToolResult(ok=False, error="Saved thing not found")
            title = item.title
            await saved.remove_item(db, item)
            return ToolResult(ok=True, data={"removed": title, "id": str(arguments["item_id"])})
    except ValueError:
        return ToolResult(ok=False, error="Dates must be YYYY-MM-DD")
    return ToolResult(ok=False, error=f"Unknown tool: {name}")


async def _save(
    db: AsyncSession,
    user_id: uuid.UUID,
    source: str,
    arguments: dict,
    context: SavedContext,
    request: str,
) -> ToolResult:
    list_name, title = _text(arguments, "list"), _text(arguments, "title")
    if not list_name or not title:
        return ToolResult(ok=False, error="list and title are required")
    data: dict = {}
    photo = await _photo_for(db, user_id, arguments, context, data)
    keep_days = arguments.get("keep_days")
    item, created = await saved.save_item(
        db, user_id,
        list_name=list_name, title=title,
        details=_text(arguments, "details"), fields=_fields(arguments),
        people=await saved.match_people(db, user_id, _names(arguments)),
        photo_id=photo.id if photo else None,
        latest_only=arguments.get("latest_only") is True,
        keep_days=keep_days if isinstance(keep_days, int) else None,
        moment=saved.Moment(
            request=request, source=source,
            conversation_id=context.conversation_id or (photo.conversation_id if photo else None),
            segment_id=context.segment_id,
        ),
        embedding_service=context.embedder(),
    )
    if arguments.get("with_place") is True:
        await _with_place(db, user_id, item, context, data)
    photo_text = context.photo_text if context.photo_id else (photo.description if photo else None)
    data.update({
        "saved": saved.describe_item(item, photo_text=(photo_text or "")[:MAX_PHOTO_TEXT] or None),
        "list": item.list.name,
        "created": created,
    })
    return ToolResult(ok=True, data=data)


async def _update(
    db: AsyncSession, user_id: uuid.UUID, arguments: dict, context: SavedContext
) -> ToolResult:
    item = await _own_item(db, user_id, arguments)
    if item is None:
        return ToolResult(ok=False, error="Saved thing not found: find it first for its id")
    data: dict = {}
    photo = await _photo_for(db, user_id, arguments, context, data)
    await saved.update_item(
        db, item,
        title=_text(arguments, "title"), details=_text(arguments, "details"),
        fields=_fields(arguments), list_name=_text(arguments, "list"),
        people=await saved.match_people(db, user_id, _names(arguments)),
        photo_id=photo.id if photo else None,
        embedding_service=context.embedder(),
    )
    if arguments.get("with_place") is True:
        await _with_place(db, user_id, item, context, data)
    photo_text = context.photo_text if context.photo_id else (photo.description if photo else None)
    data.update({
        "saved": saved.describe_item(item, photo_text=(photo_text or "")[:MAX_PHOTO_TEXT] or None),
        "list": item.list.name,
        "created": False,
    })
    return ToolResult(ok=True, data=data)


async def saved_lists_prompt(db: AsyncSession, user_id: uuid.UUID) -> str:
    """The user's lists for the agent's prompt: names, settings and how many things
    ("" when they cannot be read: the agent still saves, choosing a list by itself)."""
    try:
        rows = await db.execute(
            select(SavedList, func.count(SavedItem.id))
            .outerjoin(SavedItem, SavedItem.list_id == SavedList.id)
            .where(SavedList.user_id == user_id)
            .group_by(SavedList.id)
            .order_by(SavedList.updated_at.desc())
        )
    except Exception:
        logger.warning("Could not read the user's Saved lists", exc_info=True)
        return ""
    lists = []
    for lst, count in rows.all():
        settings = []
        if lst.latest_only:
            settings.append("latest only")
        if lst.keep_days:
            settings.append(f"kept {lst.keep_days} days")
        settings.append("1 thing" if count == 1 else f"{count} things")
        lists.append(f'"{lst.name}" ({", ".join(settings)})')
    if not lists:
        return "The user has no Saved lists yet."
    return "The user's Saved lists: " + "; ".join(lists) + "."
