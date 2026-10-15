"""Wearable firmware releases, for updates over BLE.

Revision ID: 014
Revises: 013
Create Date: 2026-10-15
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import UUID

revision: str = "014"
down_revision: Union[str, None] = "013"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    if "firmware_releases" in sa_inspect(op.get_bind()).get_table_names():
        return
    op.create_table(
        "firmware_releases",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("version", sa.String(20), nullable=False),
        sa.Column("size_bytes", sa.Integer(), nullable=False),
        sa.Column("sha256", sa.String(64), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("image", sa.LargeBinary(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.UniqueConstraint("version"),
    )


def downgrade() -> None:
    op.drop_table("firmware_releases")
