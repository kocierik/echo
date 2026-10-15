"""Voice fingerprints: profiles of known voices, and each segment's fingerprint and match.

Revision ID: 013
Revises: 012
Create Date: 2026-10-15
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from pgvector.sqlalchemy import Vector
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import UUID

revision: str = "013"
down_revision: Union[str, None] = "012"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    if "voice_profiles" not in inspector.get_table_names():
        op.create_table(
            "voice_profiles",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column("user_id", UUID(as_uuid=True), nullable=False),
            sa.Column("name", sa.String(200), nullable=False),
            sa.Column("is_self", sa.Boolean(), nullable=False, server_default=sa.false()),
            sa.Column(
                "person_id",
                UUID(as_uuid=True),
                sa.ForeignKey("entities.id", ondelete="SET NULL"),
                nullable=True,
            ),
            sa.Column("embedding", Vector(256), nullable=False),
            sa.Column("sample_count", sa.Integer(), nullable=False, server_default="0"),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                nullable=False,
                server_default=sa.func.now(),
            ),
            sa.Column(
                "updated_at",
                sa.DateTime(timezone=True),
                nullable=False,
                server_default=sa.func.now(),
            ),
        )
        op.create_index("ix_voice_profiles_user_id", "voice_profiles", ["user_id"])
        # One own voice per user
        op.create_index(
            "uq_voice_profiles_self",
            "voice_profiles",
            ["user_id"],
            unique=True,
            postgresql_where=sa.text("is_self"),
        )

    columns = {c["name"] for c in inspector.get_columns("segments")}
    if "voice_embedding" not in columns:
        op.add_column("segments", sa.Column("voice_embedding", Vector(256), nullable=True))
        op.add_column(
            "segments",
            sa.Column(
                "voice_profile_id",
                UUID(as_uuid=True),
                sa.ForeignKey("voice_profiles.id", ondelete="SET NULL"),
                nullable=True,
            ),
        )
        op.add_column("segments", sa.Column("voice_similarity", sa.Float(), nullable=True))
        op.add_column("segments", sa.Column("voice_match", sa.String(10), nullable=True))


def downgrade() -> None:
    op.drop_column("segments", "voice_match")
    op.drop_column("segments", "voice_similarity")
    op.drop_column("segments", "voice_profile_id")
    op.drop_column("segments", "voice_embedding")
    op.drop_table("voice_profiles")
