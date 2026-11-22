import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, Float, ForeignKey, String, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDPrimaryKey


class Transcription(UUIDPrimaryKey, Base):
    __tablename__ = "transcriptions"

    segment_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("segments.id", ondelete="CASCADE"), nullable=False
    )
    text: Mapped[str] = mapped_column(Text, nullable=False)
    speaker_label: Mapped[str | None] = mapped_column(String(10), nullable=True)
    language: Mapped[str] = mapped_column(String(10), nullable=False, default="it")
    confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
    )
    stt_provider: Mapped[str] = mapped_column(String(50), nullable=False)
    stt_model: Mapped[str] = mapped_column(String(50), nullable=False)
    # Several voices in the segment (told apart once the conversation closed):
    # [{"speaker": "self"|"other", "profile_id": str|None, "group": int|None, "text": str}]
    # none_as_null: None is SQL NULL, not the JSON null that `isnot(None)` lets through
    turns: Mapped[list | None] = mapped_column(JSONB(none_as_null=True), nullable=True)

    # Relationships
    segment: Mapped["Segment"] = relationship(back_populates="transcription")
    entities: Mapped[list["Entity"]] = relationship(back_populates="source_transcription")
    edits: Mapped[list["TranscriptionEdit"]] = relationship(
        back_populates="transcription",
        cascade="all, delete-orphan",
        passive_deletes=True,
    )


from app.models.entity import Entity  # noqa: E402
from app.models.segment import Segment  # noqa: E402
from app.models.transcription_edit import TranscriptionEdit  # noqa: E402
