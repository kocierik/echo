"""Places visited: the stays the phone noticed, for the users who turn it on.

Revision ID: 024
Revises: 023
Create Date: 2026-10-24

A visit is a stay of 10 minutes or more (arrived, left, where, address, name); no path
and no positions in between. One row per stay the phone sends (`key`); kept 90 days.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "024"
down_revision: Union[str, None] = "023"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "place_visits",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("key", sa.String(80), nullable=False),
        sa.Column("arrived_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("left_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("latitude", sa.Float(), nullable=False),
        sa.Column("longitude", sa.Float(), nullable=False),
        sa.Column("accuracy_m", sa.Float(), nullable=True),
        sa.Column("name", sa.Text(), nullable=True),
        sa.Column("address", sa.Text(), nullable=True),
        sa.Column("source", sa.String(10), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        "ix_place_visits_user_key", "place_visits", ["user_id", "key"], unique=True
    )
    op.create_index("ix_place_visits_user_arrived", "place_visits", ["user_id", "arrived_at"])


def downgrade() -> None:
    op.drop_index("ix_place_visits_user_arrived", table_name="place_visits")
    op.drop_index("ix_place_visits_user_key", table_name="place_visits")
    op.drop_table("place_visits")
