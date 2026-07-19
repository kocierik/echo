import uuid
from datetime import datetime

from sqlalchemy import DateTime, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, UUIDPrimaryKey


class Conversation(UUIDPrimaryKey, TimestampMixin, Base):
    __tablename__ = "conversations"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, index=True)
    title: Mapped[str | None] = mapped_column(Text, nullable=True)
    summary: Mapped[str | None] = mapped_column(Text, nullable=True)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    analysis_status: Mapped[str] = mapped_column(String(20), nullable=False, default="pending")

    # Relationships
    segments: Mapped[list["Segment"]] = relationship(back_populates="conversation")
    chunks: Mapped[list["Chunk"]] = relationship(back_populates="conversation")
    entities: Mapped[list["Entity"]] = relationship(back_populates="conversation")


from app.models.chunk import Chunk  # noqa: E402
from app.models.entity import Entity  # noqa: E402
from app.models.segment import Segment  # noqa: E402
