"""Baseline schema — matches docs/schema.sql as of MVP.

Revision ID: 001
Revises: None
Create Date: 2026-07-25

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Baseline: schema already applied via docs/schema.sql.

    This migration exists to establish the Alembic version tracking.
    On a fresh database, apply docs/schema.sql first, then stamp this revision:

        alembic stamp 001
    """
    pass


def downgrade() -> None:
    """Cannot downgrade baseline — would need to drop entire schema."""
    raise RuntimeError("Cannot downgrade past baseline. Drop the database manually if needed.")
