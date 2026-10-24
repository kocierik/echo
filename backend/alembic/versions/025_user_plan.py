"""The account's plan: how much speech a month is transcribed, web searches, routines.

Revision ID: 025
Revises: 024
Create Date: 2026-10-24

Every existing account starts on free; the operator moves it with `make set-plan`.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "025"
down_revision: Union[str, None] = "024"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "users", sa.Column("plan", sa.String(20), nullable=False, server_default="free")
    )


def downgrade() -> None:
    op.drop_column("users", "plan")
