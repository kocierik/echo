import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


def _now() -> datetime:
    return datetime.now(timezone.utc)


class DemoItem(Base):
    """One row the example data made (Profile → Example data, services/demo_data.py):
    turning it off deletes these rows, and only these."""

    __tablename__ = "demo_items"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    # "conversation" | "fact" | "saved_item" | "saved_list" | "place_visit"
    kind: Mapped[str] = mapped_column(String(20), primary_key=True)
    item_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=_now
    )
