"""The rows made by the example data (Profile → Example data), so turning it off deletes
only them.

Revision ID: 033
Revises: 032
Create Date: 2026-11-05

Additive only: one new table; downgrade drops it (the example rows stay, as plain data).
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "033"
down_revision: Union[str, None] = "032"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "demo_items",
        sa.Column("user_id", UUID(as_uuid=True), primary_key=True),
        sa.Column("kind", sa.String(20), primary_key=True),
        sa.Column("item_id", UUID(as_uuid=True), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("demo_items")
