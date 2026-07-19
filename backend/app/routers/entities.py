"""Entities API: list, search and filter extracted knowledge."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.entity import Entity
from app.services.deduplication import deduplicate_entities
from app.services.llm_openai import get_llm_analysis_service

router = APIRouter(prefix="/entities", tags=["entities"])


# --- Schemas ---


class EntityOut(BaseModel):
    id: uuid.UUID
    entity_type: str
    name: str
    content: str | None
    metadata_: dict
    conversation_id: uuid.UUID | None
    created_at: datetime

    model_config = {"from_attributes": True}


class EntityListResponse(BaseModel):
    entities: list[EntityOut]
    total: int


class EntityTypeCount(BaseModel):
    entity_type: str
    count: int


class EntityStatsResponse(BaseModel):
    total: int
    by_type: list[EntityTypeCount]


# --- Endpoints ---


@router.get("", response_model=EntityListResponse)
async def list_entities(
    entity_type: str | None = Query(None, description="Filter by type: person, task, idea, event, note"),
    search: str | None = Query(None, description="Search by name (case-insensitive)"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """List entities with optional filtering by type and name search."""
    # Base query
    base = select(Entity).where(Entity.user_id == user_id)

    # Apply filters
    if entity_type:
        base = base.where(Entity.entity_type == entity_type)
    if search:
        base = base.where(Entity.name.ilike(f"%{search}%"))

    # Count total
    count_query = select(func.count()).select_from(base.subquery())
    total = (await db.execute(count_query)).scalar() or 0

    # Fetch entities
    query = base.order_by(Entity.created_at.desc()).offset(offset).limit(limit)
    result = await db.execute(query)
    entities = result.scalars().all()

    return EntityListResponse(
        entities=[
            EntityOut(
                id=e.id,
                entity_type=e.entity_type,
                name=e.name,
                content=e.content,
                metadata_=e.metadata_,
                conversation_id=e.conversation_id,
                created_at=e.created_at,
            )
            for e in entities
        ],
        total=total,
    )


@router.get("/stats", response_model=EntityStatsResponse)
async def entity_stats(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Get entity counts grouped by type."""
    query = (
        select(Entity.entity_type, func.count(Entity.id))
        .where(Entity.user_id == user_id)
        .group_by(Entity.entity_type)
    )
    result = await db.execute(query)
    rows = result.all()

    by_type = [EntityTypeCount(entity_type=t, count=c) for t, c in rows]
    total = sum(item.count for item in by_type)

    return EntityStatsResponse(total=total, by_type=by_type)


@router.get("/people", response_model=EntityListResponse)
async def list_people(
    search: str | None = Query(None),
    limit: int = Query(50, ge=1, le=200),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Shortcut: list all people entities."""
    base = (
        select(Entity)
        .where(Entity.user_id == user_id)
        .where(Entity.entity_type == "person")
    )
    if search:
        base = base.where(Entity.name.ilike(f"%{search}%"))

    count_query = select(func.count()).select_from(base.subquery())
    total = (await db.execute(count_query)).scalar() or 0

    query = base.order_by(Entity.name).limit(limit)
    result = await db.execute(query)
    entities = result.scalars().all()

    return EntityListResponse(
        entities=[
            EntityOut(
                id=e.id, entity_type=e.entity_type, name=e.name,
                content=e.content, metadata_=e.metadata_,
                conversation_id=e.conversation_id, created_at=e.created_at,
            )
            for e in entities
        ],
        total=total,
    )


@router.get("/tasks", response_model=EntityListResponse)
async def list_tasks(
    done: bool | None = Query(None, description="Filter by completion status"),
    limit: int = Query(50, ge=1, le=200),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Shortcut: list all task entities, optionally filtered by done status."""
    base = (
        select(Entity)
        .where(Entity.user_id == user_id)
        .where(Entity.entity_type == "task")
    )

    if done is not None:
        # Filter by metadata_.done field
        base = base.where(Entity.metadata_["done"].as_boolean() == done)

    count_query = select(func.count()).select_from(base.subquery())
    total = (await db.execute(count_query)).scalar() or 0

    query = base.order_by(Entity.created_at.desc()).limit(limit)
    result = await db.execute(query)
    entities = result.scalars().all()

    return EntityListResponse(
        entities=[
            EntityOut(
                id=e.id, entity_type=e.entity_type, name=e.name,
                content=e.content, metadata_=e.metadata_,
                conversation_id=e.conversation_id, created_at=e.created_at,
            )
            for e in entities
        ],
        total=total,
    )



@router.post("/deduplicate")
async def deduplicate(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Manually trigger entity deduplication with LLM confirmation for ambiguous cases."""
    llm_service = get_llm_analysis_service()
    merged_count = await deduplicate_entities(db, user_id, llm_service)
    return {"merged": merged_count}
