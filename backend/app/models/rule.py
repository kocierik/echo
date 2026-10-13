"""Rule model: user-defined automation rules (IF this THEN that)."""

import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Integer, String, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey


class Rule(UUIDPrimaryKey, Base):
    __tablename__ = "rules"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    # Trigger conditions (all must match — AND logic)
    # Example: {"entity_type": "task", "metadata.priority": "high", "name_contains": "progetto"}
    conditions: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)

    # Actions to execute when conditions match
    # Example: [{"type": "webhook", "url": "..."}, {"type": "todoist", "project": "Work"}]
    actions: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)

    # Stats
    trigger_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_triggered_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc)
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc)
    )
