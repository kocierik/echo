"""Profile → Example data: on fills Echo with a few days of example conversations, facts,
saved things and places; off deletes them, and only them (services/demo_data.py)."""

import logging
import uuid
from datetime import timedelta

from fastapi import APIRouter, BackgroundTasks, Depends, Request
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import async_session, get_db
from app.core.timezone import to_user_local_date
from app.services import demo_data
from app.services.weekly_digest import week_start_of

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/demo", tags=["demo"])


class DemoOut(BaseModel):
    on: bool


class DemoIn(BaseModel):
    on: bool


@router.get("", response_model=DemoOut)
async def read_demo(
    user_id: uuid.UUID = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)
):
    return DemoOut(on=await demo_data.is_on(db, user_id))


def embeddings():
    """For the saved things' search (replaced in the tests)."""
    from app.services.embedding_openai import get_embedding_service

    return get_embedding_service()


@router.put("", response_model=DemoOut)
async def set_demo(
    body: DemoIn,
    request: Request,
    background: BackgroundTasks,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
    embedding_service=Depends(embeddings),
):
    if body.on:
        await demo_data.turn_on(
            db, user_id, redis_client=request.app.state.redis,
            embedding_service=embedding_service,
        )
    else:
        removed = await demo_data.turn_off(db, user_id)
        if removed.days or removed.weeks:
            background.add_task(_rewrite_summaries, user_id, removed)
    return DemoOut(on=await demo_data.is_on(db, user_id))


async def _rewrite_summaries(user_id: uuid.UUID, removed: demo_data.Removed) -> None:
    """The day and week summaries deleted with the examples, written again from what is
    left (nothing, for a day with no conversations of the user's own)."""
    from app.services.llm_openai import get_llm_analysis_service
    from app.services.weekly_digest import generate_weekly_digest
    from app.workers.digest import generate_digest_for_date

    today = to_user_local_date(demo_data._now())
    for day in removed.days:
        if day >= today:
            continue  # Today's is written tonight
        try:
            async with async_session() as db:
                await generate_digest_for_date(user_id, day, db)
        except Exception:
            logger.warning("Could not write the summary of %s again", day, exc_info=True)
    for week in removed.weeks:
        if week + timedelta(days=7) > week_start_of(today):
            continue  # This week's is written on Sunday night
        try:
            async with async_session() as db:
                await generate_weekly_digest(db, user_id, week, get_llm_analysis_service())
        except Exception:
            logger.warning("Could not write the summary of the week of %s again", week,
                           exc_info=True)

