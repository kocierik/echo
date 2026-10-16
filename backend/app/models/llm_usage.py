import uuid
from datetime import date

from sqlalchemy import BigInteger, Date, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey


class LlmUsage(UUIDPrimaryKey, Base):
    """What one user's work cost on one day, by kind of work and model (services/usage.py).

    Units: tokens for language and embedding models, seconds of audio for transcription.
    `user_id` is null for work no one owned (a gap to find, logged when it happens).
    """

    __tablename__ = "llm_usage"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "day", "kind", "model",
            name="uq_llm_usage_day", postgresql_nulls_not_distinct=True,
        ),
    )

    user_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), nullable=True)
    day: Mapped[date] = mapped_column(Date, nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    model: Mapped[str] = mapped_column(String(100), nullable=False)
    calls: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    input_units: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    output_units: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    cached_units: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
