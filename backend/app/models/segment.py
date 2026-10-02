import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDPrimaryKey


class Segment(UUIDPrimaryKey, Base):
    __tablename__ = "segments"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, index=True)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    duration_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    audio_path: Mapped[str | None] = mapped_column(Text, nullable=True)
    audio_size_bytes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    silence_before_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    audio_hash: Mapped[str | None] = mapped_column(
        String(64), nullable=True, unique=True, index=True,
        comment="SHA-256 of audio content + recorded_at for idempotency"
    )
    audio_energy: Mapped[int | None] = mapped_column(Integer, nullable=True)
    speaker: Mapped[str | None] = mapped_column(
        String(10), nullable=True, default="unknown",
        comment="self | other | unknown"
    )
    transcription_status: Mapped[str] = mapped_column(
        String(20), nullable=False, default="pending"
    )
    conversation_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("conversations.id", ondelete="CASCADE"),
        nullable=True,
    )

    # Relationships
    transcription: Mapped["Transcription | None"] = relationship(
        back_populates="segment", uselist=False, lazy="selectin", passive_deletes=True
    )
    conversation: Mapped["Conversation | None"] = relationship(back_populates="segments")


# Avoid circular import
from app.models.conversation import Conversation  # noqa: E402
from app.models.transcription import Transcription  # noqa: E402
