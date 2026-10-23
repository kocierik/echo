"""Saved: things the user asks Echo to keep and find again, each with its moment.

One generic mechanism for every case (the car, the passport, a wine, a book, receipts):
a thing has a title, free details and fields, optionally a photo and a place, the moment
it was saved (the request as said, who was named, the conversation around it) and the
list it belongs to. Lists are made by Echo from what the user says; a list may keep only
its latest thing (`latest_only`: parking again replaces the car) and keep its things for a
few days only (`keep_days`).

Used by the agent's tools (actions/saved_tools.py), memory retrieval and the app's API.
Nothing here calls a model, and nothing commits: the caller does.
"""

import logging
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation

from sqlalchemy import Text, cast, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timezone import user_zone
from app.models.entity import Entity
from app.models.saved import SavedItem, SavedList
from app.services.people import names_person

logger = logging.getLogger(__name__)

MAX_LIST_NAME = 80
# A thing found by meaning only when this close
MIN_SIMILARITY = 0.35
DEFAULT_CURRENCY = "EUR"

_CURRENCIES = {"€": "EUR", "$": "USD", "£": "GBP", "eur": "EUR", "usd": "USD", "gbp": "GBP"}

# Words that say nothing about what is looked for (Italian and English)
_STOP_WORDS = {
    "che", "cosa", "cos", "come", "quando", "dove", "dov", "chi", "quale", "quanto",
    "quel", "quello", "quella", "quei", "quelle", "questo", "questa", "era", "sono", "ho",
    "hai", "mio", "mia", "miei", "mie", "del", "della", "dei", "delle", "con", "per",
    "una", "uno", "gli", "nel", "nella", "sul", "sulla", "salvato", "salvata", "messo",
    "the", "what", "where", "which", "was", "were", "with", "that", "this", "did", "my",
    "and", "for", "from", "saved", "put", "is", "are", "about",
}


@dataclass
class Moment:
    """When and how a thing was saved: the request as said, typed or by voice, and the
    conversation it was said in (a voice request's segment, grouped later)."""

    request: str | None = None
    source: str = "chat"
    conversation_id: uuid.UUID | None = None
    segment_id: uuid.UUID | None = None


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _key(text: str) -> str:
    return " ".join((text or "").split()).lower()


async def find_list(db: AsyncSession, user_id: uuid.UUID, name: str) -> SavedList | None:
    """The user's list by name, ignoring case and spaces."""
    wanted = _key(name)
    if not wanted:
        return None
    return (
        await db.execute(
            select(SavedList)
            .where(SavedList.user_id == user_id)
            .where(func.lower(SavedList.name) == wanted)
            .limit(1)
        )
    ).scalar_one_or_none()


async def _list_for(
    db: AsyncSession,
    user_id: uuid.UUID,
    name: str,
    latest_only: bool | None = None,
    keep_days: int | None = None,
) -> SavedList:
    """The list, created with its settings when it does not exist yet (an existing list
    keeps its own)."""
    found = await find_list(db, user_id, name)
    if found is not None:
        return found
    lst = SavedList(
        id=uuid.uuid4(),
        user_id=user_id,
        name=" ".join(name.split())[:MAX_LIST_NAME],
        latest_only=bool(latest_only),
        keep_days=keep_days if keep_days and keep_days > 0 else None,
    )
    db.add(lst)
    await db.flush()
    return lst


def _embedding_text(item: SavedItem, list_name: str) -> str:
    fields = "; ".join(f"{k}: {v}" for k, v in (item.fields or {}).items())
    people = ", ".join(p.get("name", "") for p in item.people or [])
    return ". ".join(
        part for part in (list_name, item.title, item.details, fields, people) if part
    )


async def _embed(item: SavedItem, list_name: str, embedding_service) -> None:
    if embedding_service is None:
        return
    try:
        item.embedding = await embedding_service.embed(_embedding_text(item, list_name))
    except Exception:
        # Still found by its words; never lose the save over it
        logger.warning("Could not embed a saved thing", exc_info=True)


async def save_item(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    list_name: str,
    title: str,
    moment: Moment,
    details: str | None = None,
    fields: dict | None = None,
    people: list[dict] | None = None,
    photo_id: uuid.UUID | None = None,
    place: dict | None = None,
    latest_only: bool | None = None,
    keep_days: int | None = None,
    embedding_service=None,
) -> tuple[SavedItem, bool]:
    """Save a thing in `list_name` (started when new). Returns it and whether it is new.

    A thing with the same title in the same list is updated instead (saving the passport
    again moves it). In a latest-only list a new thing replaces the others.
    """
    lst = await _list_for(db, user_id, list_name, latest_only, keep_days)
    title = " ".join(title.split())
    now = _utcnow()
    same = (
        await db.execute(
            select(SavedItem)
            .where(SavedItem.list_id == lst.id)
            .where(func.lower(SavedItem.title) == title.lower())
            .limit(1)
        )
    ).scalar_one_or_none()
    if same is not None:
        # Saved again: a new moment for it
        same.request_text = moment.request or same.request_text
        same.conversation_id = moment.conversation_id or same.conversation_id
        same.segment_id = moment.segment_id or same.segment_id
        await update_item(
            db, same, details=details, fields=fields, people=people, photo_id=photo_id,
            place=place, embedding_service=embedding_service,
        )
        return same, False

    item = SavedItem(
        id=uuid.uuid4(),
        user_id=user_id,
        list_id=lst.id,
        title=title,
        details=(details or "").strip() or None,
        fields=_clean_fields(fields or {}),
        photo_id=photo_id,
        place=place,
        people=people or [],
        conversation_id=moment.conversation_id,
        segment_id=moment.segment_id,
        request_text=moment.request,
        source=moment.source if moment.source in ("chat", "voice") else "chat",
        created_at=now,
        updated_at=now,
    )
    item.list = lst
    await _embed(item, lst.name, embedding_service)
    db.add(item)
    if lst.latest_only:
        others = await db.scalars(
            select(SavedItem).where(SavedItem.list_id == lst.id, SavedItem.id != item.id)
        )
        for other in others:
            await db.delete(other)
    lst.updated_at = now
    await db.flush()
    return item, True


def _clean_fields(fields: dict) -> dict:
    return {
        str(k).strip(): v
        for k, v in fields.items()
        if str(k).strip() and v is not None and v != ""
    }


async def update_item(
    db: AsyncSession,
    item: SavedItem,
    *,
    title: str | None = None,
    details: str | None = None,
    fields: dict | None = None,
    list_name: str | None = None,
    people: list[dict] | None = None,
    photo_id: uuid.UUID | None = None,
    place: dict | None = None,
    embedding_service=None,
) -> SavedItem:
    """Change a thing: what is given replaces what it had, fields are merged (a field set
    to None is removed), the place and the photo change only when given; `list_name`
    moves it (to a list started when new)."""
    now = _utcnow()
    if title and title.strip():
        item.title = " ".join(title.split())
    if details is not None and details.strip():
        item.details = details.strip()
    if fields:
        merged = dict(item.fields or {})
        for key, value in fields.items():
            if value is None or value == "":
                merged.pop(str(key).strip(), None)
            else:
                merged[str(key).strip()] = value
        # Reassign (not mutate) so SQLAlchemy sees the JSONB change
        item.fields = merged
    if people:
        known = {_key(p.get("name", "")) for p in item.people or []}
        item.people = [
            *(item.people or []),
            *(p for p in people if _key(p.get("name", "")) not in known),
        ]
    if photo_id is not None:
        item.photo_id = photo_id
    if place is not None:
        item.place = place
    if list_name and _key(list_name) != _key(item.list.name):
        lst = await _list_for(db, item.user_id, list_name)
        item.list_id = lst.id
        item.list = lst
    item.updated_at = now
    item.list.updated_at = now
    await _embed(item, item.list.name, embedding_service)
    await db.flush()
    return item


async def match_people(db: AsyncSession, user_id: uuid.UUID, names: list[str]) -> list[dict]:
    """The people named in a request, matched to People by first or full name:
    [{"name", "id"}] (id None for someone Echo does not know)."""
    wanted = [" ".join(str(n).split()) for n in names if str(n).strip()]
    if not wanted:
        return []
    known = list(
        await db.scalars(
            select(Entity)
            .where(Entity.user_id == user_id, Entity.entity_type == "person")
            .order_by(Entity.updated_at.desc())
        )
    )
    people: list[dict] = []
    for name in wanted:
        person = next(
            (p for p in known if _key(p.name) == _key(name)), None
        ) or next((p for p in known if names_person(p.name, name)), None)
        entry = {"name": person.name, "id": str(person.id)} if person else {"name": name, "id": None}
        if entry not in people:
            people.append(entry)
    return people


def _words(query: str) -> list[str]:
    """The query's words worth looking for, cut to a rough stem ("vino" finds "Vini")."""
    words = []
    for raw in re.split(r"[\s'’]+", query.lower()):
        word = raw.strip("?.,!:;\"()«»")
        if len(word) < 3 or word in _STOP_WORDS:
            continue
        stem = word[:-1] if len(word) >= 4 else word
        if stem not in words:
            words.append(stem)
    return words


def _period(query, date_from: datetime | None, date_to: datetime | None):
    if date_from is not None:
        query = query.where(SavedItem.created_at >= date_from)
    if date_to is not None:
        query = query.where(SavedItem.created_at < date_to)
    return query


async def find_items(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    query: str | None = None,
    list_name: str | None = None,
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    limit: int = 10,
    embedding_service=None,
) -> list[SavedItem]:
    """Things matching the query's words (title, details, fields, list, people) and, with
    an embedding service, its meaning; in a list and a period when given. Newest first,
    the word matches before the others. Without a query: the newest things."""
    base = (
        select(SavedItem)
        .join(SavedList, SavedList.id == SavedItem.list_id)
        .where(SavedItem.user_id == user_id)
    )
    if list_name:
        base = base.where(func.lower(SavedList.name) == _key(list_name))
    base = _period(base, date_from, date_to)
    newest = SavedItem.created_at.desc()
    words = _words(query or "")
    if not words and not (query or "").strip():
        return list((await db.scalars(base.order_by(newest).limit(limit))).unique())

    found: list[SavedItem] = []
    if words:
        matches = [
            or_(
                SavedItem.title.ilike(f"%{word}%"),
                SavedItem.details.ilike(f"%{word}%"),
                cast(SavedItem.fields, Text).ilike(f"%{word}%"),
                cast(SavedItem.people, Text).ilike(f"%{word}%"),
                SavedList.name.ilike(f"%{word}%"),
            )
            for word in words
        ]
        found = list(
            (await db.scalars(base.where(or_(*matches)).order_by(newest).limit(limit))).unique()
        )
    if embedding_service is not None and len(found) < limit and (query or "").strip():
        try:
            vector = await embedding_service.embed(query)
        except Exception:
            logger.warning("Could not embed a Saved search", exc_info=True)
            return found
        similarity = 1 - SavedItem.embedding.cosine_distance(vector)
        rows = await db.execute(
            base.add_columns(similarity.label("similarity"))
            .where(SavedItem.embedding.isnot(None))
            .order_by(SavedItem.embedding.cosine_distance(vector))
            .limit(limit)
        )
        seen = {item.id for item in found}
        for item, score in rows.unique().all():
            if score > MIN_SIMILARITY and item.id not in seen and len(found) < limit:
                found.append(item)
    return found


def parse_amount(value) -> tuple[Decimal | None, str | None]:
    """An amount from a number or a text ("12,50", "€ 7.90", "1.234,50 €", "$3") and the
    currency its text names, if any."""
    if isinstance(value, bool):
        return None, None
    if isinstance(value, (int, float, Decimal)):
        return Decimal(str(value)), None
    if not isinstance(value, str):
        return None, None
    text = value.strip()
    currency = next(
        (code for mark, code in _CURRENCIES.items() if mark in text.lower()), None
    )
    number = re.sub(r"[^0-9.,-]", "", text)
    if not re.search(r"\d", number):
        return None, None
    if "." in number and "," in number:
        decimal_mark = "," if number.rfind(",") > number.rfind(".") else "."
        thousands = "." if decimal_mark == "," else ","
        number = number.replace(thousands, "").replace(decimal_mark, ".")
    elif "," in number:
        number = number.replace(",", ".")
    elif re.fullmatch(r"-?\d{1,3}(\.\d{3})+", number):
        number = number.replace(".", "")
    try:
        return Decimal(number), currency
    except InvalidOperation:
        return None, None


async def sum_items(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    list_name: str | None = None,
    field: str = "amount",
    date_from: datetime | None = None,
    date_to: datetime | None = None,
) -> dict:
    """The total of a numeric field over a list and a period, per currency:
    {"list", "count", "totals": {"EUR": 184.3}}. Things without the field are skipped."""
    query = (
        select(SavedItem)
        .join(SavedList, SavedList.id == SavedItem.list_id)
        .where(SavedItem.user_id == user_id)
    )
    lst = None
    if list_name:
        lst = await find_list(db, user_id, list_name)
        if lst is None:
            return {"list": list_name, "count": 0, "totals": {}}
        query = query.where(SavedItem.list_id == lst.id)
    items = (await db.scalars(_period(query, date_from, date_to))).unique()
    totals: dict[str, Decimal] = {}
    count = 0
    for item in items:
        fields = item.fields or {}
        amount, named = parse_amount(fields.get(field))
        if amount is None:
            continue
        currency = str(fields.get("currency") or named or DEFAULT_CURRENCY).upper()
        currency = _CURRENCIES.get(currency.lower(), currency)
        totals[currency] = totals.get(currency, Decimal(0)) + amount
        count += 1
    return {
        "list": lst.name if lst else None,
        "count": count,
        "totals": {code: float(round(total, 2)) for code, total in totals.items()},
    }


async def remove_item(db: AsyncSession, item: SavedItem) -> None:
    """Delete the thing only (never its photo: it stays in the memory and the thread)."""
    await db.delete(item)
    await db.flush()


async def expire_items(db: AsyncSession, now: datetime) -> int:
    """Delete the things older than their list's `keep_days`; the lists stay. Commits."""
    rows = await db.execute(
        select(SavedItem, SavedList.keep_days)
        .join(SavedList, SavedList.id == SavedItem.list_id)
        .where(SavedList.keep_days.isnot(None))
    )
    expired = [
        item for item, days in rows.unique().all()
        if item.created_at < now - timedelta(days=days)
    ]
    for item in expired:
        await db.delete(item)
    await db.commit()
    return len(expired)


def _local(moment: datetime) -> str:
    return moment.astimezone(user_zone()).strftime("%A %Y-%m-%d %H:%M")


def describe_item(
    item: SavedItem, *, include_place: bool = True, photo_text: str | None = None
) -> dict:
    """The thing for the model: what it is, where it was saved, its moment. Without
    `include_place` (outside assistants) no address and no coordinates."""
    described: dict = {
        "id": str(item.id),
        "list": item.list.name,
        "title": item.title,
        "saved_at": _local(item.created_at),
    }
    if item.details:
        described["details"] = item.details
    if item.fields:
        described["fields"] = item.fields
    if item.people:
        described["with"] = [p.get("name") for p in item.people]
    if include_place and item.place and item.place.get("address"):
        described["address"] = item.place["address"]
    if item.photo_id is not None:
        described["has_photo"] = True
    if photo_text:
        described["photo_text"] = photo_text
    return described


def item_line(item: SavedItem, *, include_place: bool = True) -> str:
    """One line of the "Saved things" context of a memory answer."""
    line = f"- [{item.list.name}] {item.title}"
    if item.details:
        line += f": {item.details}"
    if item.fields:
        line += " (" + ", ".join(f"{k}: {v}" for k, v in item.fields.items()) + ")"
    line += f". Saved {_local(item.created_at)}"
    if item.people:
        line += ", with " + ", ".join(p.get("name", "") for p in item.people)
    if include_place and item.place and item.place.get("address"):
        line += f". Place: {item.place['address']}"
    if item.request_text:
        line += f'. Asked: "{item.request_text}"'
    return line
