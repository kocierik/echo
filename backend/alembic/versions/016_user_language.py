"""The language each account speaks, for transcription and dictation.

Revision ID: 016
Revises: 015
Create Date: 2026-10-16
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "016"
down_revision: Union[str, None] = "015"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Existing accounts keep today's behaviour: everything was transcribed in Italian
    op.add_column(
        "users",
        sa.Column("language", sa.String(5), nullable=False, server_default="it"),
    )


def downgrade() -> None:
    op.drop_column("users", "language")
