import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, LargeBinary, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, deferred, mapped_column

from app.models.base import Base, TimestampMixin, UUIDPrimaryKey


class Photo(UUIDPrimaryKey, TimestampMixin, Base):
    """A photo from the wearable camera, asked for by voice ("Echo, …") or from the app.

    Lifecycle: "requested" (waiting for the wearable) -> "received" (image stored,
    queued for the vision model) -> "done" (answered in the chat, described in memory),
    or "failed" (the wearable could not take it, or it never arrived).
    The image lives here, not on the wearable; it is deleted with the chat session or
    the conversation it belongs to.
    """

    __tablename__ = "photos"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, index=True)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="requested")
    # "voice" or "app"
    source: Mapped[str] = mapped_column(String(10), nullable=False)
    # What the user asked ("Echo, what plant is this?"); None for a plain photo
    question: Mapped[str | None] = mapped_column(Text, nullable=True)
    chat_session_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("chat_sessions.id", ondelete="CASCADE"), nullable=True
    )
    conversation_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("conversations.id", ondelete="CASCADE"),
        nullable=True,
        index=True,
    )
    captured_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Loaded only when asked for: listing photos never reads the bytes
    image: Mapped[bytes | None] = deferred(mapped_column(LargeBinary, nullable=True))
    image_sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    size_bytes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # For memory search; the answer to `question` goes to the chat
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    answer: Mapped[str | None] = mapped_column(Text, nullable=True)
    error: Mapped[str | None] = mapped_column(String(40), nullable=True)
