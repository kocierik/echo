"""Profile → Health: the iPhone's Health app, sent each day by Apple's Shortcuts
(services/health.py). The shortcut posts with a key that can only do that; the app shows
the last days, makes that key and deletes everything."""

import secrets
import uuid
from datetime import date

from fastapi import APIRouter, Body, Depends, Request, Response, status
from pydantic import BaseModel
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import get_current_api_key, get_current_user_id, get_health_writer, hash_api_key
from app.core.database import get_db
from app.core.rate_limit import limiter
from app.models.api_key import ApiKey
from app.services import health

router = APIRouter(prefix="/health", tags=["health"])

# Its name in Profile → Devices, where it can be revoked like the others
SHORTCUT_KEY_NAME = "Comandi rapidi (Salute)"


class HealthDayOut(BaseModel):
    day: date
    sleep_minutes: int | None
    steps: int | None
    distance_km: float | None
    active_kcal: int | None
    exercise_minutes: int | None
    resting_hr: int | None
    workouts: str | None


class HealthDaysOut(BaseModel):
    days: list[HealthDayOut]


class ShortcutKeyOut(BaseModel):
    api_key: str
    # Where the shortcut posts, after the server's address
    path: str


def _out(day) -> HealthDayOut:
    return HealthDayOut(
        day=day.day, sleep_minutes=day.sleep_minutes, steps=day.steps,
        distance_km=day.distance_km, active_kcal=day.active_kcal,
        exercise_minutes=day.exercise_minutes, resting_hr=day.resting_hr,
        workouts=day.workouts,
    )


@router.post("/day", response_model=HealthDayOut)
@limiter.limit("30/minute")
async def receive_day(
    request: Request,
    body: dict = Body(default_factory=dict),
    key: ApiKey = Depends(get_health_writer),
    db: AsyncSession = Depends(get_db),
):
    """One day from Shortcuts: {date, sleep, steps, distance, active_kcal, exercise_minutes,
    resting_hr, workouts}, each optional. Answers what was understood, so the shortcut's
    result shows it."""
    values = health.read_day(body if isinstance(body, dict) else {}, health.today())
    await health.save_day(db, key.user_id, values, source="shortcuts")
    await db.commit()
    return HealthDayOut(**values)


@router.get("/days", response_model=HealthDaysOut)
async def read_days(
    user_id: uuid.UUID = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)
):
    return HealthDaysOut(days=[_out(d) for d in await health.recent_days(db, user_id)])


@router.post("/key", response_model=ShortcutKeyOut)
async def make_shortcut_key(
    current: ApiKey = Depends(get_current_api_key), db: AsyncSession = Depends(get_db)
):
    """A new key for the shortcut (shown once); the one made before stops working."""
    await db.execute(
        delete(ApiKey).where(ApiKey.user_id == current.user_id, ApiKey.scope == "health")
    )
    key = secrets.token_urlsafe(32)
    db.add(ApiKey(
        user_id=current.user_id, key_hash=hash_api_key(key), name=SHORTCUT_KEY_NAME,
        scope="health",
    ))
    await db.commit()
    return ShortcutKeyOut(api_key=key, path="/api/health/day")


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
async def forget_health(
    current: ApiKey = Depends(get_current_api_key), db: AsyncSession = Depends(get_db)
):
    """Every day kept, and the shortcut's key: nothing more arrives."""
    await health.forget(db, current.user_id)
    await db.execute(
        delete(ApiKey).where(ApiKey.user_id == current.user_id, ApiKey.scope == "health")
    )
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
