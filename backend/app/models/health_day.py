import uuid
from datetime import date, datetime, timezone

from sqlalchemy import Date, DateTime, Float, Integer, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


def _now() -> datetime:
    return datetime.now(timezone.utc)


class HealthDay(Base):
    """One day of the iPhone's Health app, as Apple's Shortcuts send it (Profile → Health,
    services/health.py): what the user's answers can use. Any of it may be missing."""

    __tablename__ = "health_days"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    day: Mapped[date] = mapped_column(Date, primary_key=True)
    # Asleep, the night that ended this morning
    sleep_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    steps: Mapped[int | None] = mapped_column(Integer, nullable=True)
    distance_km: Mapped[float | None] = mapped_column(Float, nullable=True)
    active_kcal: Mapped[int | None] = mapped_column(Integer, nullable=True)
    exercise_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    resting_hr: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # The day's workouts as the shortcut words them ("Corsa 32 min, 5,1 km")
    workouts: Mapped[str | None] = mapped_column(Text, nullable=True)
    # "shortcuts" (Apple's Shortcuts), "demo" (Profile → Example data)
    source: Mapped[str] = mapped_column(String(12), nullable=False, default="shortcuts")
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=_now, onupdate=_now
    )
