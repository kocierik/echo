"""Add an emoji to conversations, written with the title and summary.

Revision ID: 009
Revises: 008
Create Date: 2026-10-14

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy import inspect as sa_inspect

revision: str = "009"
down_revision: Union[str, None] = "008"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    columns = {c["name"] for c in sa_inspect(op.get_bind()).get_columns("conversations")}
    if "emoji" not in columns:
        op.add_column("conversations", sa.Column("emoji", sa.String(16), nullable=True))


def downgrade() -> None:
    op.drop_column("conversations", "emoji")
