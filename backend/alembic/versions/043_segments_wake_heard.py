"""Whether the pendant heard its wake phrase in a segment.

Revision ID: 043
Revises: 042
Create Date: 2026-11-13

From firmware 0.11.0 the pendant recognises its wake phrase and the phone uploads the
segment with X-Wake-Heard: 1. Kept beside what the transcript says, it measures the model
in daily use: requests the pendant missed, and phrases it heard that nobody said.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect

from alembic import op

revision: str = "043"
down_revision: Union[str, None] = "042"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    if "wake_heard" not in {c["name"] for c in inspector.get_columns("segments")}:
        op.add_column(
            "segments",
            sa.Column("wake_heard", sa.Boolean(), nullable=False, server_default=sa.false()),
        )


def downgrade() -> None:
    op.drop_column("segments", "wake_heard")
