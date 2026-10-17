"""Key permissions: `full` (phones, scripts) or `read` (connected apps, MCP only).

Revision ID: 018
Revises: 017
Create Date: 2026-10-16
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "018"
down_revision: Union[str, None] = "017"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Every existing key keeps doing what it did
    op.add_column(
        "api_keys",
        sa.Column("scope", sa.String(10), nullable=False, server_default="full"),
    )


def downgrade() -> None:
    op.drop_column("api_keys", "scope")
