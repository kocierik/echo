"""People: everyone Echo heard about, and what is linked to each of them."""

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.person_fact import PersonFact
from app.models.transcription import Transcription
from app.routers.conversations import ConversationListItem, list_items, with_segment_counts
from app.services.people import in_person_conversations, naming
from app.services.person_facts import current_facts, earlier_facts

router = APIRouter(prefix="/people", tags=["people"])

MAX_PERSON_CONVERSATIONS = 30
MAX_PERSON_ITEMS = 20


class PersonSummary(BaseModel):
    id: uuid.UUID
    name: str
    role: str | None
    # What Echo learned about them (accumulated across conversations)
    about: str | None
    last_seen: datetime | None
    conversation_count: int
    open_task_count: int


class PersonItem(BaseModel):
    """A task or event that names the person."""

    id: uuid.UUID
    entity_type: str
    name: str
    content: str | None
    metadata_: dict
    conversation_id: uuid.UUID | None
    created_at: datetime
    source_text: str | None


class FactOut(BaseModel):
    id: uuid.UUID
    text: str
    category: str
    quote: str
    conversation_id: uuid.UUID | None
    created_at: datetime


class PersonDetail(PersonSummary):
    conversations: list[ConversationListItem]
    tasks: list[PersonItem]
    events: list[PersonItem]
    facts: list[FactOut]
    earlier_facts: list[FactOut]


def _role(person: Entity) -> str | None:
    role = (person.metadata_ or {}).get("role")
    return role.strip() if isinstance(role, str) and role.strip() else None


def _open_tasks_naming(person: Entity, user_id: uuid.UUID):
    return (
        select(Entity)
        .where(Entity.user_id == user_id)
        .where(Entity.entity_type == "task")
        .where(func.coalesce(Entity.metadata_["done"].as_boolean(), False).is_(False))
        .where(naming(person.name))
    )


async def _summary(db: AsyncSession, person: Entity, user_id: uuid.UUID) -> PersonSummary:
    last_seen, count = (
        await db.execute(
            select(func.max(Conversation.started_at), func.count(Conversation.id))
            .where(Conversation.user_id == user_id)
            .where(in_person_conversations(person))
        )
    ).one()
    open_tasks = (
        await db.execute(
            select(func.count()).select_from(_open_tasks_naming(person, user_id).subquery())
        )
    ).scalar() or 0
    return PersonSummary(
        id=person.id,
        name=person.name,
        role=_role(person),
        about=person.content,
        last_seen=last_seen,
        conversation_count=count,
        open_task_count=open_tasks,
    )


async def _owned_person(db: AsyncSession, person_id: uuid.UUID, user_id: uuid.UUID) -> Entity:
    person = (
        await db.execute(
            select(Entity)
            .where(Entity.id == person_id)
            .where(Entity.user_id == user_id)
            .where(Entity.entity_type == "person")
        )
    ).scalar_one_or_none()
    if person is None:
        raise HTTPException(status_code=404, detail="Person not found")
    return person


def _item(entity: Entity, source_text: str | None) -> PersonItem:
    return PersonItem(
        id=entity.id,
        entity_type=entity.entity_type,
        name=entity.name,
        content=entity.content,
        metadata_=entity.metadata_,
        conversation_id=entity.conversation_id,
        created_at=entity.created_at,
        source_text=source_text,
    )


def _fact(fact: PersonFact) -> FactOut:
    return FactOut(
        id=fact.id,
        text=fact.text,
        category=fact.category,
        quote=fact.quote,
        conversation_id=fact.conversation_id,
        created_at=fact.created_at,
    )


@router.get("", response_model=list[PersonSummary])
async def list_people(
    limit: int = Query(100, ge=1, le=200),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Everyone Echo heard about, most recently seen first (never seen: by name, last)."""
    people = (
        await db.execute(
            select(Entity)
            .where(Entity.user_id == user_id)
            .where(Entity.entity_type == "person")
            .limit(limit)
        )
    ).scalars().all()
    summaries = [await _summary(db, person, user_id) for person in people]
    return sorted(
        summaries,
        key=lambda p: (
            p.last_seen is None,
            -(p.last_seen.timestamp() if p.last_seen else 0.0),
            p.name.lower(),
        ),
    )


@router.get("/{person_id}", response_model=PersonDetail)
async def get_person(
    person_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """A person with the conversations they came up in, and the tasks and events naming them."""
    person = await _owned_person(db, person_id, user_id)
    summary = await _summary(db, person, user_id)

    conversation_rows = (
        await db.execute(
            with_segment_counts(
                Conversation.user_id == user_id, in_person_conversations(person)
            ).limit(MAX_PERSON_CONVERSATIONS)
        )
    ).all()

    task_rows = await db.execute(
        _open_tasks_naming(person, user_id)
        .add_columns(Transcription.text)
        .outerjoin(Transcription, Transcription.id == Entity.source_transcription_id)
        .order_by(Entity.created_at.desc())
        .limit(MAX_PERSON_ITEMS)
    )
    event_rows = await db.execute(
        select(Entity, Transcription.text)
        .outerjoin(Transcription, Transcription.id == Entity.source_transcription_id)
        .where(Entity.user_id == user_id)
        .where(Entity.entity_type == "event")
        .where(naming(person.name))
        .order_by(Entity.created_at.desc())
        .limit(MAX_PERSON_ITEMS)
    )

    return PersonDetail(
        **summary.model_dump(),
        conversations=await list_items(db, conversation_rows),
        tasks=[_item(e, text) for e, text in task_rows.all()],
        events=[_item(e, text) for e, text in event_rows.all()],
        facts=[_fact(fact) for fact in await current_facts(db, user_id, person.id)],
        earlier_facts=[_fact(fact) for fact in await earlier_facts(db, user_id, person.id)],
    )


@router.delete(
    "/{person_id}/facts/{fact_id}",
    status_code=204,
)
async def reject_person_fact(
    person_id: uuid.UUID,
    fact_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Reject a fact about an owned person without deleting its history."""
    await _owned_person(db, person_id, user_id)
    fact = (
        await db.execute(
            select(PersonFact)
            .where(PersonFact.id == fact_id)
            .where(PersonFact.person_id == person_id)
            .where(PersonFact.user_id == user_id)
        )
    ).scalar_one_or_none()
    if fact is None:
        raise HTTPException(status_code=404, detail="Fact not found")
    fact.status = "rejected"
    fact.rejected_at = datetime.now(timezone.utc)
    await db.commit()
    return Response(status_code=204)
