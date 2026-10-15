"""Weekly summaries.

Revision ID: 012
Revises: 011
Create Date: 2026-10-15
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "012"
down_revision: Union[str, None] = "011"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    if "weekly_digests" in sa_inspect(op.get_bind()).get_table_names():
        return
    op.create_table(
        "weekly_digests",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("week_start", sa.Date(), nullable=False),
        sa.Column("summary", sa.Text(), nullable=False),
        sa.Column("highlights", JSONB(), nullable=False, server_default="[]"),
        sa.Column("people", JSONB(), nullable=False, server_default="[]"),
        sa.Column("conversation_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("tasks_created", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.UniqueConstraint("user_id", "week_start"),
    )
    op.create_index("ix_weekly_digests_user_id", "weekly_digests", ["user_id"])


def downgrade() -> None:
    op.drop_table("weekly_digests")
