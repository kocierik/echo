"""The user's own instructions to Echo (Profile → Instructions), added to every answer.

Revision ID: 022
Revises: 021
Create Date: 2026-10-23
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "022"
down_revision: Union[str, None] = "021"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("instructions", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "instructions")
