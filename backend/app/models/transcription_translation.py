import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, ForeignKey, String, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey


class TranscriptionTranslation(UUIDPrimaryKey, Base):
    """A transcript line in another language, kept so it is translated once
    (services/transcript_translation.py); dropped when the line's text is corrected."""

    __tablename__ = "transcription_translations"
    __table_args__ = (
        UniqueConstraint(
            "transcription_id", "language", name="uq_transcription_translations_language"
        ),
    )

    transcription_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(
            "transcriptions.id",
            name="fk_transcription_translations_transcription",
            ondelete="CASCADE",
        ),
        nullable=False,
    )
    language: Mapped[str] = mapped_column(String(10), nullable=False)
    text: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
    )
