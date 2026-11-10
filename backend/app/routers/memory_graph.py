import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.services.memory_graph import memory_graph as build_memory_graph

router = APIRouter(prefix="/memory-graph", tags=["memory graph"])


@router.get("")
async def get_memory_graph(
    days: int = Query(90, ge=0, le=3650),
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
) -> dict:
    """Return the authenticated user's weighted people and topic graph."""
    return await build_memory_graph(db, user_id, days)
