import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, ForeignKey, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey


class UserFact(UUIDPrimaryKey, Base):
    """A sentence about the user (Profile → Memory → About you): kept ones go into every
    answer (services/personal.py); suggested ones wait for Keep or Discard."""

    __tablename__ = "user_facts"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    text: Mapped[str] = mapped_column(String(200), nullable=False)
    # "kept" | "suggested" | "discarded" (a suggestion the user turned down: not again)
    status: Mapped[str] = mapped_column(String(10), nullable=False)
    # "you" | "echo" | "conversation"
    source: Mapped[str] = mapped_column(String(15), nullable=False)
    conversation_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("conversations.id", name="fk_user_facts_conversation", ondelete="SET NULL"),
        nullable=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc)
    )
