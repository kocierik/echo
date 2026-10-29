"""Assistants: Echo focused on one part of the user's life (work, diet, sleep).

Revision ID: 029
Revises: 028
Create Date: 2026-10-29

A chat or a routine may belong to one; deleting the assistant leaves them to plain Echo.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "029"
down_revision: Union[str, None] = "028"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "assistants",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(40), nullable=False),
        sa.Column("emoji", sa.String(16), nullable=False),
        sa.Column("instructions", sa.Text, nullable=False),
        # What it keeps about its topic: shown, editable, updated by the assistant
        sa.Column("notes", sa.Text, nullable=False, server_default=""),
        # Its documents; empty: all of the user's
        sa.Column("document_ids", JSONB, nullable=False, server_default="[]"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_assistants_user_id", "assistants", ["user_id"])
    for table in ("chat_sessions", "routines"):
        op.add_column(table, sa.Column("assistant_id", UUID(as_uuid=True), nullable=True))
        op.create_foreign_key(
            f"fk_{table}_assistant", table, "assistants", ["assistant_id"], ["id"],
            ondelete="SET NULL",
        )


def downgrade() -> None:
    for table in ("routines", "chat_sessions"):
        op.drop_constraint(f"fk_{table}_assistant", table, type_="foreignkey")
        op.drop_column(table, "assistant_id")
    op.drop_table("assistants")
