"""Run tracking: one row per coordinator request or routine run, and one per step.

Revision ID: 031
Revises: 030
Create Date: 2026-10-30

Additive only: two new tables, nothing existing changes. They stay empty until
RUN_TRACKING_ENABLED is turned on (core/runs.py); downgrade drops them.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "031"
down_revision: Union[str, None] = "030"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "agent_runs",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("correlation_id", sa.String(64), nullable=False),
        sa.Column("user_id", UUID(as_uuid=True), nullable=True),
        sa.Column("source", sa.String(10), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="running"),
        sa.Column("plan_summary", sa.String(200), nullable=True),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("tokens_in", sa.Integer, nullable=False, server_default="0"),
        sa.Column("tokens_out", sa.Integer, nullable=False, server_default="0"),
        sa.Column("cost_usd", sa.Numeric(12, 6), nullable=False, server_default="0"),
        sa.Column("cost_unknown", sa.Boolean, nullable=False, server_default=sa.false()),
        sa.Column("error_class", sa.String(64), nullable=True),
        sa.CheckConstraint(
            "(status = 'running') = (ended_at IS NULL)", name="ck_agent_runs_ended_when_final"
        ),
        sa.CheckConstraint(
            "ended_at IS NULL OR ended_at >= started_at", name="ck_agent_runs_ended_after_start"
        ),
    )
    op.create_index("ix_agent_runs_user_started", "agent_runs", ["user_id", "started_at"])
    op.create_index("ix_agent_runs_correlation_id", "agent_runs", ["correlation_id"])
    op.create_index("ix_agent_runs_started_at", "agent_runs", ["started_at"])

    op.create_table(
        "agent_steps",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("run_id", UUID(as_uuid=True), nullable=False),
        sa.Column("seq", sa.Integer, nullable=False),
        sa.Column("kind", sa.String(20), nullable=False),
        sa.Column("agent_id", sa.String(80), nullable=True),
        sa.Column("tool_name", sa.String(120), nullable=True),
        sa.Column("model", sa.String(80), nullable=True),
        sa.Column("tier", sa.String(10), nullable=True),
        sa.Column("attempt", sa.Integer, nullable=False, server_default="1"),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("duration_ms", sa.Integer, nullable=False, server_default="0"),
        sa.Column("tokens_in", sa.Integer, nullable=False, server_default="0"),
        sa.Column("tokens_out", sa.Integer, nullable=False, server_default="0"),
        sa.Column("cost_usd", sa.Numeric(12, 6), nullable=False, server_default="0"),
        sa.Column("cost_unknown", sa.Boolean, nullable=False, server_default=sa.false()),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("error_class", sa.String(64), nullable=True),
        sa.Column("args_redacted", JSONB, nullable=True),
        sa.Column("action_log_id", UUID(as_uuid=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["run_id"], ["agent_runs.id"], name="fk_agent_steps_run", ondelete="CASCADE"
        ),
        sa.UniqueConstraint("run_id", "seq", name="uq_agent_steps_run_seq"),
    )


def downgrade() -> None:
    op.drop_table("agent_steps")
    op.drop_table("agent_runs")
