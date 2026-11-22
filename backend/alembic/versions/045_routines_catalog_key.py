"""Routines added from the catalog: which entry each one came from.

Revision ID: 045
Revises: 044
Create Date: 2026-11-22

The app's catalog of ready-made routines (services/routine_catalog.py) shows which entries
are already added, and removes them, by this key. Routines asked for in words keep none.

A routine can also run after each conversation (schedule kind "after_conversation"):
`last_conversation_at` is the end of the last conversation it ran on.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect

from alembic import op

revision: str = "045"
down_revision: Union[str, None] = "044"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    columns = {c["name"] for c in inspector.get_columns("routines")}
    if "catalog_key" not in columns:
        op.add_column("routines", sa.Column("catalog_key", sa.String(40), nullable=True))
    if "last_conversation_at" not in columns:
        op.add_column(
            "routines",
            sa.Column("last_conversation_at", sa.DateTime(timezone=True), nullable=True),
        )


def downgrade() -> None:
    op.drop_column("routines", "last_conversation_at")
    op.drop_column("routines", "catalog_key")
