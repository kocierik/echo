"""A closed conversation is transcribed again whole: when that was done.

Revision ID: 036
Revises: 035
Create Date: 2026-11-08

Each segment (one to six seconds) was transcribed alone: without the sentences around
it the speech-to-text guessed words and even the language ("Siems five years"). Once a
conversation is closed its audio goes once more as one recording, and the words go back
to their segments (services/retranscription.py). The conversations already there are
marked done: their audio is gone after a day.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy import inspect as sa_inspect

revision: str = "036"
down_revision: Union[str, None] = "035"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    columns = {c["name"] for c in sa_inspect(op.get_bind()).get_columns("conversations")}
    if "retranscribed_at" not in columns:
        op.add_column(
            "conversations",
            sa.Column("retranscribed_at", sa.DateTime(timezone=True), nullable=True),
        )
        op.execute("UPDATE conversations SET retranscribed_at = now()")


def downgrade() -> None:
    op.drop_column("conversations", "retranscribed_at")
