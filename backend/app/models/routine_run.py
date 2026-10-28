import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, String, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey


class RoutineRun(UUIDPrimaryKey, Base):
    """One run of a routine (workers/routines.py): what it found, or that it had nothing to
    say, could not run or was missed.

    The one source for Today's "From your routines", Ask → Routines and Profile → Routines,
    and for what an `only_new` routine already reported (`items`). Never in the chat thread
    unless the user sends it there ("Ask about this"). Deleted with its routine, or after
    90 days (services/routine_runs.py).
    """

    __tablename__ = "routine_runs"
    __table_args__ = (Index("ix_routine_runs_user_ran", "user_id", "ran_at"),)

    routine_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("routines.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, index=True)
    ran_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    # "reported" | "nothing" (quiet only_if / only_new run) | "failed" | "skipped"
    status: Mapped[str] = mapped_column(String(10), nullable=False)
    # The answer in full; None for "nothing" and "skipped"
    text: Mapped[str | None] = mapped_column(Text, nullable=True)
    # The web pages cited: [{"title", "url"}], as an answer's citations
    sources: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    # only_new: what this run reported, [{"key", "title", "url"}] (services/routine_results.py)
    items: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
