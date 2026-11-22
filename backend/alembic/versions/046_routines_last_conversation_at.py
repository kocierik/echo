"""Routines run after each conversation: the last conversation each one ran on.

Revision ID: 046
Revises: 045
Create Date: 2026-11-22

A routine with schedule kind "after_conversation" runs on each conversation once it is
closed and summarized (workers/routines.run_conversation_routines); this is the end of
the last one it ran on.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect

from alembic import op

revision: str = "046"
down_revision: Union[str, None] = "045"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    if "last_conversation_at" not in {c["name"] for c in inspector.get_columns("routines")}:
        op.add_column(
            "routines",
            sa.Column("last_conversation_at", sa.DateTime(timezone=True), nullable=True),
        )


def downgrade() -> None:
    op.drop_column("routines", "last_conversation_at")
