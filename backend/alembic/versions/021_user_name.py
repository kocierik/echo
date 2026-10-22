"""The user's name, for the app's greeting; the voice session becomes the thread "Echo".

Revision ID: 021
Revises: 020
Create Date: 2026-10-22
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "021"
down_revision: Union[str, None] = "020"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Nullable: without a name the app greets without one
    op.add_column("users", sa.Column("name", sa.String(100), nullable=True))
    # The voice session is Ask's one thread with Echo now
    op.execute("UPDATE chat_sessions SET title = 'Echo' WHERE kind = 'voice'")


def downgrade() -> None:
    op.execute("UPDATE chat_sessions SET title = 'Voice requests' WHERE kind = 'voice'")
    op.drop_column("users", "name")
