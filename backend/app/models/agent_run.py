import uuid
from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDPrimaryKey

# What a run is and how it ended (core/runs.py)
RUN_SOURCES = ("chat", "voice", "routine")
RUN_STATUSES = ("running", "completed", "failed", "timeout", "budget_exceeded", "interrupted")
STEP_KINDS = ("plan", "delegation", "llm_call", "tool_call", "synthesis")
STEP_STATUSES = ("ok", "failed", "refused", "timeout", "unknown", "skipped")


class AgentRun(UUIDPrimaryKey, Base):
    """One tracked run: a request the coordinator handled, or a routine's run.

    Written by core/runs.py in its own session, so the record survives the request's
    rollback; read by `make runs`. No user text is ever stored here: `plan_summary` holds
    only agent ids, and the cost is an estimate from app/usage_prices.py, with
    `cost_unknown` set when a step used a model that has no price. A run leaves `running`
    once (`ended_at` is set exactly then); runs and their steps go after 30 days
    (workers/retention.py).
    """

    __tablename__ = "agent_runs"
    __table_args__ = (
        Index("ix_agent_runs_user_started", "user_id", "started_at"),
        CheckConstraint(
            "(status = 'running') = (ended_at IS NULL)", name="ck_agent_runs_ended_when_final"
        ),
        CheckConstraint(
            "ended_at IS NULL OR ended_at >= started_at", name="ck_agent_runs_ended_after_start"
        ),
    )

    # The same ID as the request's (or the worker job's) JSON logs
    correlation_id: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    # None only for work no user owns; never for chat, voice or a routine
    user_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), nullable=True)
    # RUN_SOURCES
    source: Mapped[str] = mapped_column(String(10), nullable=False)
    # RUN_STATUSES
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="running")
    # Agent ids, comma-separated, built by code from the registry: never the model's text
    plan_summary: Mapped[str | None] = mapped_column(String(200), nullable=True)
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, index=True
    )
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    tokens_in: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    tokens_out: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # Sum of the steps' known costs (USD, an estimate)
    cost_usd: Mapped[Decimal] = mapped_column(Numeric(12, 6), nullable=False, default=0)
    cost_unknown: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # The exception class or the reason (`interrupted`, `cancelled`), never its message
    error_class: Mapped[str | None] = mapped_column(String(64), nullable=True)


class AgentStep(UUIDPrimaryKey, Base):
    """One step of a run: a plan, a delegation, a model call, a tool call or a synthesis.

    `seq` numbers the steps of a run in the order they were recorded. Tool arguments are
    kept only as key names with each value's type and length (core/redaction.py
    `redact_for_tracking`); deleting the run deletes its steps.
    """

    __tablename__ = "agent_steps"
    __table_args__ = (UniqueConstraint("run_id", "seq", name="uq_agent_steps_run_seq"),)

    run_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("agent_runs.id", ondelete="CASCADE"), nullable=False
    )
    seq: Mapped[int] = mapped_column(Integer, nullable=False)
    # STEP_KINDS
    kind: Mapped[str] = mapped_column(String(20), nullable=False)
    agent_id: Mapped[str | None] = mapped_column(String(80), nullable=True)
    tool_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    model: Mapped[str | None] = mapped_column(String(80), nullable=True)
    # READ | CREATE | CONFIRM (actions/policy.py), tool calls only
    tier: Mapped[str | None] = mapped_column(String(10), nullable=True)
    attempt: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    duration_ms: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    tokens_in: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    tokens_out: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    cost_usd: Mapped[Decimal] = mapped_column(Numeric(12, 6), nullable=False, default=0)
    cost_unknown: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # STEP_STATUSES
    status: Mapped[str] = mapped_column(String(10), nullable=False)
    error_class: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # Tool calls only: {"subject": "str(42)", "event_id": "abc"} (never the values)
    args_redacted: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    # The action_log row, when the tool call was audited
    action_log_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), nullable=True)
