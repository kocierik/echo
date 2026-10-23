from sqlalchemy import String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, TimestampMixin, UUIDPrimaryKey


class User(UUIDPrimaryKey, TimestampMixin, Base):
    """An account: signing in with it gives a phone its own API key."""

    __tablename__ = "users"

    # Stored stripped and lower-cased (normalize_email)
    email: Mapped[str] = mapped_column(String(320), nullable=False, unique=True)
    # Argon2id (app/services/passwords.py)
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    # The language the user speaks: the wearable's transcription and the app's dictation
    language: Mapped[str] = mapped_column(String(5), nullable=False, server_default="it")
    # What the app calls the user ("Good afternoon, Erik"); none until they give one
    name: Mapped[str | None] = mapped_column(String(100), nullable=True)
    # The user's own instructions to Echo, added to every answer (services/personal.py)
    instructions: Mapped[str | None] = mapped_column(Text, nullable=True)
