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
from app.models.transcription import Transcription
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
    # The transcript sentence the entity was extracted from (filled for tasks)
    source_text: str | None = None

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
    entity_type: str | None = Query(
        None, description="Filter by type: person, task, idea, event, note"
    ),
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
        # A task without metadata.done (as extracted) is open
        base = base.where(func.coalesce(Entity.metadata_["done"].as_boolean(), False) == done)

    count_query = select(func.count()).select_from(base.subquery())
    total = (await db.execute(count_query)).scalar() or 0

    rows = await db.execute(
        base.add_columns(Transcription.text)
        .outerjoin(Transcription, Transcription.id == Entity.source_transcription_id)
        .order_by(Entity.created_at.desc())
        .limit(limit)
    )

    return EntityListResponse(
        entities=[
            EntityOut(
                id=e.id, entity_type=e.entity_type, name=e.name,
                content=e.content, metadata_=e.metadata_,
                conversation_id=e.conversation_id, created_at=e.created_at,
                source_text=source_text,
            )
            for e, source_text in rows.all()
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


# --- CRUD endpoints ---


class EntityUpdate(BaseModel):
    name: str | None = None
    content: str | None = None
    entity_type: str | None = None
    metadata_: dict | None = None


class MergeRequest(BaseModel):
    target_id: uuid.UUID


@router.patch("/{entity_id}", response_model=EntityOut)
async def update_entity(
    entity_id: uuid.UUID,
    update: EntityUpdate,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Update an entity's fields. Queues re-embedding if name changes."""
    from fastapi import HTTPException

    result = await db.execute(
        select(Entity)
        .where(Entity.id == entity_id)
        .where(Entity.user_id == user_id)
    )
    entity = result.scalar_one_or_none()
    if entity is None:
        raise HTTPException(status_code=404, detail="Entity not found")

    name_changed = False
    if update.name is not None and update.name != entity.name:
        entity.name = update.name
        name_changed = True
    if update.content is not None:
        entity.content = update.content
    if update.entity_type is not None:
        entity.entity_type = update.entity_type
    if update.metadata_ is not None:
        entity.metadata_ = update.metadata_

    from datetime import timezone

    entity.updated_at = datetime.now(timezone.utc)

    # Re-embed if name changed (embedding is based on name + content)
    if name_changed:
        from app.services.embedding_openai import get_embedding_service

        embedding_service = get_embedding_service()
        text_to_embed = f"{entity.name}: {entity.content}" if entity.content else entity.name
        entity.embedding = await embedding_service.embed(text_to_embed)

    return EntityOut(
        id=entity.id,
        entity_type=entity.entity_type,
        name=entity.name,
        content=entity.content,
        metadata_=entity.metadata_,
        conversation_id=entity.conversation_id,
        created_at=entity.created_at,
    )


@router.delete("/{entity_id}", status_code=204)
async def delete_entity(
    entity_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Delete an entity."""
    from fastapi import HTTPException

    result = await db.execute(
        select(Entity)
        .where(Entity.id == entity_id)
        .where(Entity.user_id == user_id)
    )
    entity = result.scalar_one_or_none()
    if entity is None:
        raise HTTPException(status_code=404, detail="Entity not found")

    await db.delete(entity)


@router.post("/{entity_id}/merge", response_model=EntityOut)
async def merge_entity_endpoint(
    entity_id: uuid.UUID,
    body: MergeRequest,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Merge source entity into target. Deletes source, returns updated target."""
    from fastapi import HTTPException

    from app.services.deduplication import merge_entities

    # Fetch source
    source_result = await db.execute(
        select(Entity).where(Entity.id == entity_id).where(Entity.user_id == user_id)
    )
    source = source_result.scalar_one_or_none()
    if source is None:
        raise HTTPException(status_code=404, detail="Source entity not found")

    # Fetch target
    target_result = await db.execute(
        select(Entity).where(Entity.id == body.target_id).where(Entity.user_id == user_id)
    )
    target = target_result.scalar_one_or_none()
    if target is None:
        raise HTTPException(status_code=404, detail="Target entity not found")

    await merge_entities(db, target, source)

    return EntityOut(
        id=target.id,
        entity_type=target.entity_type,
        name=target.name,
        content=target.content,
        metadata_=target.metadata_,
        conversation_id=target.conversation_id,
        created_at=target.created_at,
    )
