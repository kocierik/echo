"""A routine's mode, and one row per run: routines that speak only when needed.

Revision ID: 026
Revises: 025
Create Date: 2026-10-28

Existing routines are `always`: they keep reporting every run, as before.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "026"
down_revision: Union[str, None] = "025"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "routines", sa.Column("mode", sa.String(10), nullable=False, server_default="always")
    )
    op.create_table(
        "routine_runs",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("routine_id", UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("ran_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("text", sa.Text, nullable=True),
        sa.Column("sources", JSONB, nullable=False, server_default="[]"),
        sa.Column("items", JSONB, nullable=False, server_default="[]"),
        sa.ForeignKeyConstraint(
            ["routine_id"], ["routines.id"], name="fk_routine_runs_routine", ondelete="CASCADE"
        ),
    )
    op.create_index("ix_routine_runs_routine_id", "routine_runs", ["routine_id"])
    op.create_index("ix_routine_runs_user_id", "routine_runs", ["user_id"])
    op.create_index("ix_routine_runs_user_ran", "routine_runs", ["user_id", "ran_at"])


def downgrade() -> None:
    op.drop_table("routine_runs")
    op.drop_column("routines", "mode")
