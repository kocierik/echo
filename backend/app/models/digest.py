import uuid
from datetime import date, datetime, timezone

from sqlalchemy import Date, DateTime, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey


class Digest(UUIDPrimaryKey, Base):
    __tablename__ = "digests"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, index=True)
    digest_date: Mapped[date] = mapped_column(Date, nullable=False)
    summary: Mapped[str] = mapped_column(Text, nullable=False)
    people: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    tasks: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    ideas: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    events: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    conversation_count: Mapped[int] = mapped_column(nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )
