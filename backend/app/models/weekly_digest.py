import uuid
from datetime import date, datetime, timezone

from sqlalchemy import Date, DateTime, Integer, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey


class WeeklyDigest(UUIDPrimaryKey, Base):
    """A summary of one week (Monday to Sunday, user's timezone)."""

    __tablename__ = "weekly_digests"
    __table_args__ = (UniqueConstraint("user_id", "week_start"),)

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, index=True)
    week_start: Mapped[date] = mapped_column(Date, nullable=False)  # a Monday
    summary: Mapped[str] = mapped_column(Text, nullable=False)
    # A few short lines: decisions, news, things to follow up
    highlights: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    # [{"name", "conversations"}], most present first
    people: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    conversation_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    tasks_created: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )
