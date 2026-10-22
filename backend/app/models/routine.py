import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Index, String, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey


class Routine(UUIDPrimaryKey, Base):
    """Something Echo does on its own at a time the user asked for (services/routines.py).

    Created by asking Echo; run by workers/routines.py at `next_run_at` (UTC), the
    schedule's wall time in `timezone`. The answer goes to the user's thread with Echo.
    """

    __tablename__ = "routines"
    __table_args__ = (Index("ix_routines_due", "active", "next_run_at"),)

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, index=True)
    # The request in the user's words: "dimmi che tempo fa a Milano"
    instruction: Mapped[str] = mapped_column(Text, nullable=False)
    # {"kind", "time", "days"?, "day_of_month"?} (services/routines.validate_schedule)
    schedule: Mapped[dict] = mapped_column(JSONB, nullable=False)
    timezone: Mapped[str] = mapped_column(String(64), nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    next_run_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_run_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # "ok" | "failed" | "skipped" (missed by more than the catch-up window)
    last_status: Mapped[str | None] = mapped_column(String(10), nullable=True)
    last_answer: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Where it was asked for: "chat" | "voice"
    source: Mapped[str] = mapped_column(String(10), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc)
    )
