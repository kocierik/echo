"""The account's plan and this month's speech (Profile → Plan, and Today's line once the
budget is used). Read only: the operator sets plans (`make set-plan`) until payments exist.
"""

import uuid
from datetime import date

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.services.plans import plan_usage

router = APIRouter(prefix="/plan", tags=["plan"])


class PlanOut(BaseModel):
    plan: str
    monthly_seconds: int
    # Transcribed this calendar month (UTC)
    used_seconds: int
    # Past the budget, still transcribed each day at once
    daily_seconds: int
    # Speech kept and waiting for the budget
    deferred_seconds: int
    # The budget starts again (UTC)
    resets_on: date
    over_budget: bool
    web_searches_per_day: int
    routines: int
    # Spoken answers may use Echo's natural voices (Profile → Spoken answers → Voice)
    premium_voice: bool = False


@router.get("", response_model=PlanOut)
async def read_plan(
    user_id: uuid.UUID = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)
):
    usage = await plan_usage(db, user_id)
    return PlanOut(
        plan=usage.plan.name,
        monthly_seconds=usage.budget_seconds,
        used_seconds=usage.used_seconds,
        daily_seconds=usage.plan.daily_minutes * 60,
        deferred_seconds=usage.deferred_seconds,
        resets_on=usage.resets_on,
        over_budget=usage.over_budget,
        web_searches_per_day=usage.plan.web_searches_per_day,
        routines=usage.plan.routines,
        premium_voice=bool(usage.plan.premium_voice),
    )
