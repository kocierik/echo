import uuid
from datetime import datetime, timezone

from pgvector.sqlalchemy import Vector
from sqlalchemy import Boolean, DateTime, ForeignKey, Index, Integer, String, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UUIDPrimaryKey


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class SavedList(UUIDPrimaryKey, Base):
    """A list of saved things ("Wines", "Where things are", "Your car"), made by Echo from
    what the user says (services/saved.py). Kept when it empties: its settings stay for
    the next thing (the car's list keeps being latest-only)."""

    __tablename__ = "saved_lists"
    __table_args__ = (Index("ix_saved_lists_user_name", "user_id", "name", unique=True),)

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    # Only its latest thing is kept: saving another replaces it (the car)
    latest_only: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # Its things are deleted this many days after they were saved; None: kept
    keep_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=_utcnow
    )
    # The last time a thing was saved or changed in it
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=_utcnow
    )


class SavedItem(UUIDPrimaryKey, Base):
    """Something the user asked Echo to keep and find again, with its moment.

    One generic thing for every case: a title, free details and fields ({"amount": 12.5,
    "vintage": "2019", "level": "-2"}), optionally a photo and a place (only when the user
    asked for it), who was there and the conversation around it. The photo and the
    conversation may be deleted: the thing stays, with its text.
    """

    __tablename__ = "saved_items"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, index=True)
    list_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("saved_lists.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    title: Mapped[str] = mapped_column(Text, nullable=False)
    details: Mapped[str | None] = mapped_column(Text, nullable=True)
    fields: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    photo_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("photos.id", ondelete="SET NULL"), nullable=True
    )
    # {"latitude", "longitude", "accuracy_m", "address"}, from the phone when asked
    place: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    # Who was there, as named in the request: [{"name", "id"}] (id: the person, if known)
    people: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    conversation_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("conversations.id", ondelete="SET NULL"), nullable=True
    )
    # A voice request's segment: its conversation once the segment is grouped
    segment_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("segments.id", ondelete="SET NULL"), nullable=True
    )
    # The user's request as said ("its line" in the moment)
    request_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    # "chat" | "voice"
    source: Mapped[str] = mapped_column(String(10), nullable=False)
    # Of the title, details and fields: memory answers find it by meaning
    embedding = mapped_column(Vector(1536), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=_utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=_utcnow
    )

    list: Mapped[SavedList] = relationship(lazy="joined")
