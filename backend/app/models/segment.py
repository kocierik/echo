import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import DateTime, Float, ForeignKey, Integer, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, deferred, mapped_column, relationship

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
    # Voice fingerprint of the segment (computed while the audio exists) and the voice
    # profile it was matched to: "auto" (sure), "suggested" (asked in the transcript)
    # or "confirmed" (by the user)
    voice_embedding = deferred(mapped_column(Vector(256), nullable=True))
    voice_profile_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("voice_profiles.id", ondelete="SET NULL"), nullable=True
    )
    voice_similarity: Mapped[float | None] = mapped_column(Float, nullable=True)
    voice_match: Mapped[str | None] = mapped_column(String(10), nullable=True)
    # An unknown voice told apart from the conversation's others: 2 is "Person 2"
    # (services/voice_profiles.py number_unknown_voices); None when there was one at most
    voice_group: Mapped[int | None] = mapped_column(Integer, nullable=True)

    # Relationships
    transcription: Mapped["Transcription | None"] = relationship(
        back_populates="segment", uselist=False, lazy="selectin", passive_deletes=True
    )
    conversation: Mapped["Conversation | None"] = relationship(back_populates="segments")


# Avoid circular import
from app.models.conversation import Conversation  # noqa: E402
from app.models.transcription import Transcription  # noqa: E402
