"""Photos from the wearable camera, and their description chunks.

Revision ID: 011
Revises: 010
Create Date: 2026-10-14

A photo is asked for by voice or from the app, taken by the wearable, stored here
(the wearable keeps nothing) and described by a vision model: the answer goes to the
chat, the description to memory as a chunk that survives transcript reanalysis.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import UUID

revision: str = "011"
down_revision: Union[str, None] = "010"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    if "photos" not in inspector.get_table_names():
        op.create_table(
            "photos",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column("user_id", UUID(as_uuid=True), nullable=False),
            sa.Column("status", sa.String(20), nullable=False, server_default="requested"),
            sa.Column("source", sa.String(10), nullable=False),
            sa.Column("question", sa.Text(), nullable=True),
            sa.Column(
                "chat_session_id",
                UUID(as_uuid=True),
                sa.ForeignKey("chat_sessions.id", ondelete="CASCADE"),
                nullable=True,
            ),
            sa.Column(
                "conversation_id",
                UUID(as_uuid=True),
                sa.ForeignKey("conversations.id", ondelete="CASCADE"),
                nullable=True,
            ),
            sa.Column("captured_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("image", sa.LargeBinary(), nullable=True),
            sa.Column("image_sha256", sa.String(64), nullable=True),
            sa.Column("size_bytes", sa.Integer(), nullable=True),
            sa.Column("description", sa.Text(), nullable=True),
            sa.Column("answer", sa.Text(), nullable=True),
            sa.Column("error", sa.String(40), nullable=True),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                nullable=False,
                server_default=sa.func.now(),
            ),
        )
        op.create_index("ix_photos_user_id", "photos", ["user_id"])
        op.create_index("ix_photos_conversation_id", "photos", ["conversation_id"])
        op.create_index("ix_photos_status", "photos", ["status"])

    if "photo_id" not in {c["name"] for c in inspector.get_columns("chunks")}:
        op.add_column(
            "chunks",
            sa.Column(
                "photo_id",
                UUID(as_uuid=True),
                sa.ForeignKey("photos.id", ondelete="CASCADE"),
                nullable=True,
            ),
        )
        op.create_index("ix_chunks_photo_id", "chunks", ["photo_id"])


def downgrade() -> None:
    op.drop_index("ix_chunks_photo_id", table_name="chunks")
    op.drop_column("chunks", "photo_id")
    op.drop_table("photos")
