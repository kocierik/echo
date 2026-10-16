import uuid
from datetime import datetime

from sqlalchemy import DateTime, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, TimestampMixin, UUIDPrimaryKey


class ApiKey(UUIDPrimaryKey, TimestampMixin, Base):
    __tablename__ = "api_keys"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    key_hash: Mapped[str] = mapped_column(Text, nullable=False, unique=True)
    # The phone's name for keys given at sign-in ("iPhone"), else a label
    name: Mapped[str] = mapped_column(String(100), nullable=False, default="default")
    # "ios" or "android" for keys given at sign-in; None for keys made with make create-key
    platform: Mapped[str | None] = mapped_column(String(20), nullable=True)
    # "full": the REST API (phones, scripts); "read": connected apps, on the MCP server only
    scope: Mapped[str] = mapped_column(String(10), nullable=False, server_default="full")
    last_used_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
