"""Accounts, and the phone a sign-in key belongs to.

Revision ID: 015
Revises: 014
Create Date: 2026-10-16
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import UUID

revision: str = "015"
down_revision: Union[str, None] = "014"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    if "users" not in inspector.get_table_names():
        op.create_table(
            "users",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column("email", sa.String(320), nullable=False),
            sa.Column("password_hash", sa.Text(), nullable=False),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                nullable=False,
                server_default=sa.func.now(),
            ),
            sa.UniqueConstraint("email"),
        )
    if "platform" not in {c["name"] for c in inspector.get_columns("api_keys")}:
        op.add_column("api_keys", sa.Column("platform", sa.String(20), nullable=True))


def downgrade() -> None:
    op.drop_column("api_keys", "platform")
    op.drop_table("users")
