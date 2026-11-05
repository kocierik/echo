"""A day of the iPhone's Health app, sent by Apple's Shortcuts (Profile → Health).

Revision ID: 034
Revises: 033
Create Date: 2026-11-05

Additive only: one new table; downgrade drops it.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "034"
down_revision: Union[str, None] = "033"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "health_days",
        sa.Column("user_id", UUID(as_uuid=True), primary_key=True),
        sa.Column("day", sa.Date(), primary_key=True),
        sa.Column("sleep_minutes", sa.Integer(), nullable=True),
        sa.Column("steps", sa.Integer(), nullable=True),
        sa.Column("distance_km", sa.Float(), nullable=True),
        sa.Column("active_kcal", sa.Integer(), nullable=True),
        sa.Column("exercise_minutes", sa.Integer(), nullable=True),
        sa.Column("resting_hr", sa.Integer(), nullable=True),
        sa.Column("workouts", sa.Text(), nullable=True),
        sa.Column("source", sa.String(12), nullable=False, server_default="shortcuts"),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("health_days")
