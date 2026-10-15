"""Digest API: daily summaries of the user's memory."""

import uuid
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.core.timezone import to_user_local_date
from app.models.digest import Digest
from app.models.weekly_digest import WeeklyDigest
from app.services.llm_openai import get_llm_analysis_service
from app.services.weekly_digest import generate_weekly_digest, week_start_of
from app.workers.digest import generate_digest_for_date

router = APIRouter(prefix="/digest", tags=["digest"])


class DigestResponse(BaseModel):
    id: uuid.UUID
    digest_date: date
    summary: str
    people: list
    tasks: list
    ideas: list
    events: list
    conversation_count: int
    created_at: datetime

    model_config = {"from_attributes": True}


class DigestListResponse(BaseModel):
    items: list[DigestResponse]
    count: int


@router.get("", response_model=DigestListResponse)
async def list_digests(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
    days: int = Query(default=7, ge=1, le=90, description="Number of days to look back"),
):
    """List recent daily digests for the user."""
    cutoff = to_user_local_date(datetime.now(timezone.utc)) - timedelta(days=days)

    query = (
        select(Digest)
        .where(Digest.user_id == user_id)
        .where(Digest.digest_date >= cutoff)
        .order_by(Digest.digest_date.desc())
    )
    result = await db.execute(query)
    digests = result.scalars().all()

    return DigestListResponse(
        items=[DigestResponse.model_validate(d) for d in digests],
        count=len(digests),
    )


class WeeklyDigestResponse(BaseModel):
    id: uuid.UUID
    week_start: date
    summary: str
    highlights: list[str]
    people: list[dict]
    conversation_count: int
    tasks_created: int
    created_at: datetime

    model_config = {"from_attributes": True}


class WeeklyDigestListResponse(BaseModel):
    items: list[WeeklyDigestResponse]
    count: int


# Before "/{target_date}": "weekly" is not a date
@router.get("/weekly", response_model=WeeklyDigestListResponse)
async def list_weekly_digests(
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
    weeks: int = Query(default=4, ge=1, le=52, description="Number of weeks to look back"),
):
    """Recent weekly summaries, newest first."""
    this_week = week_start_of(to_user_local_date(datetime.now(timezone.utc)))
    result = await db.execute(
        select(WeeklyDigest)
        .where(WeeklyDigest.user_id == user_id)
        .where(WeeklyDigest.week_start >= this_week - timedelta(weeks=weeks))
        .order_by(WeeklyDigest.week_start.desc())
    )
    items = result.scalars().all()
    return WeeklyDigestListResponse(
        items=[WeeklyDigestResponse.model_validate(w) for w in items], count=len(items)
    )


@router.post("/weekly/{week_start}", response_model=WeeklyDigestResponse)
async def generate_weekly(
    week_start: date,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Write (or rewrite) the summary of a week; the current week so far is allowed."""
    if week_start.weekday() != 0:
        raise HTTPException(status_code=422, detail="week_start must be a Monday")
    if week_start > to_user_local_date(datetime.now(timezone.utc)):
        raise HTTPException(status_code=400, detail="Cannot summarize a future week")
    weekly = await generate_weekly_digest(
        db, user_id, week_start, get_llm_analysis_service(), replace=True
    )
    if weekly is None:
        raise HTTPException(status_code=404, detail="No conversations that week")
    return WeeklyDigestResponse.model_validate(weekly)


@router.get("/{target_date}", response_model=DigestResponse)
async def get_digest(
    target_date: date,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Get the digest for a specific date."""
    query = (
        select(Digest)
        .where(Digest.user_id == user_id)
        .where(Digest.digest_date == target_date)
    )
    result = await db.execute(query)
    digest = result.scalar_one_or_none()

    if digest is None:
        raise HTTPException(status_code=404, detail="Digest not found for this date")

    return DigestResponse.model_validate(digest)


@router.post("/{target_date}", response_model=DigestResponse)
async def generate_digest(
    target_date: date,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Manually trigger digest generation for a specific date.

    Useful for generating digests for past days or re-generating today's digest.
    """
    # Don't allow future dates
    if target_date > to_user_local_date(datetime.now(timezone.utc)):
        raise HTTPException(status_code=400, detail="Cannot generate digest for future dates")

    # Delete existing digest for this date (allows regeneration)
    existing_query = (
        select(Digest)
        .where(Digest.user_id == user_id)
        .where(Digest.digest_date == target_date)
    )
    result = await db.execute(existing_query)
    existing = result.scalar_one_or_none()
    if existing:
        await db.delete(existing)
        await db.commit()

    # Generate
    digest = await generate_digest_for_date(user_id, target_date, db)

    if digest is None:
        raise HTTPException(
            status_code=404,
            detail="No conversations found for this date — nothing to summarize",
        )

    return DigestResponse.model_validate(digest)
