import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, Float, Index, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class PlaceVisit(UUIDPrimaryKey, Base):
    """A stay the phone noticed (Profile → Places visited, off by default): when the user
    arrived and left, where, the address and, when the phone knows it, the place's name.

    Only stays of 10 minutes or more (services/places.py); no path between places and no
    positions kept. The phone sends a stay as it starts and again when it ends, with the
    same `key`: one row. Deleted after 90 days, or by the user.
    """

    __tablename__ = "place_visits"
    __table_args__ = (
        Index("ix_place_visits_user_key", "user_id", "key", unique=True),
        Index("ix_place_visits_user_arrived", "user_id", "arrived_at"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    # Made by the phone for the stay ("ios:<arrival s>", "android:<arrival ms>")
    key: Mapped[str] = mapped_column(String(80), nullable=False)
    arrived_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    # None while the user is still there
    left_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    accuracy_m: Mapped[float | None] = mapped_column(Float, nullable=True)
    # Apple's place name on iPhone ("Trattoria da Mario"), when there is one
    name: Mapped[str | None] = mapped_column(Text, nullable=True)
    # From the phone's geocoder ("Via Roma 12, Milano")
    address: Mapped[str | None] = mapped_column(Text, nullable=True)
    # "ios" | "android"
    source: Mapped[str] = mapped_column(String(10), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=_utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=_utcnow
    )
