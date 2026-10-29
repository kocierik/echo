import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, String, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey


def _now() -> datetime:
    return datetime.now(timezone.utc)


class Assistant(UUIDPrimaryKey, Base):
    """Echo focused on one part of the user's life (Profile → Assistants): its own
    instructions, notes and documents; chats and routines may belong to it
    (services/assistants.py)."""

    __tablename__ = "assistants"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    name: Mapped[str] = mapped_column(String(40), nullable=False)
    emoji: Mapped[str] = mapped_column(String(16), nullable=False)
    instructions: Mapped[str] = mapped_column(Text, nullable=False)
    # What it keeps about its topic: shown, editable, updated by the assistant
    notes: Mapped[str] = mapped_column(Text, nullable=False, server_default="", default="")
    # Its documents; empty: all of the user's
    document_ids: Mapped[list[str]] = mapped_column(
        JSONB, nullable=False, server_default="[]", default=list
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=_now, onupdate=_now
    )
