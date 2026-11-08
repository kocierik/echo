"""Unknown voices told apart within a conversation: "Person 2", "Person 3".

Revision ID: 037
Revises: 036
Create Date: 2026-11-08

Every voice that was not the user's or a named one was "Others": three people talking
looked like one. Once a conversation is closed its unknown voices are grouped by their
fingerprints and numbered (services/voice_profiles.py); naming one names its group.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy import inspect as sa_inspect

revision: str = "037"
down_revision: Union[str, None] = "036"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    columns = {c["name"] for c in sa_inspect(op.get_bind()).get_columns("segments")}
    if "voice_group" not in columns:
        op.add_column("segments", sa.Column("voice_group", sa.Integer(), nullable=True))


def downgrade() -> None:
    op.drop_column("segments", "voice_group")
