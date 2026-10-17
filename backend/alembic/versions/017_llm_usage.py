"""Model usage per user and day: tokens and seconds of audio, by kind of work and model.

Revision ID: 017
Revises: 016
Create Date: 2026-10-16
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "017"
down_revision: Union[str, None] = "016"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "llm_usage",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), nullable=True),
        sa.Column("day", sa.Date(), nullable=False),
        sa.Column("kind", sa.String(32), nullable=False),
        sa.Column("model", sa.String(100), nullable=False),
        sa.Column("calls", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("input_units", sa.BigInteger(), nullable=False, server_default="0"),
        sa.Column("output_units", sa.BigInteger(), nullable=False, server_default="0"),
        sa.Column("cached_units", sa.BigInteger(), nullable=False, server_default="0"),
        # One row per user, day, kind and model, the "no user" row too
        sa.UniqueConstraint(
            "user_id", "day", "kind", "model",
            name="uq_llm_usage_day", postgresql_nulls_not_distinct=True,
        ),
    )


def downgrade() -> None:
    op.drop_table("llm_usage")
