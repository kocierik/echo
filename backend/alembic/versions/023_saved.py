"""Saved: things the user asks Echo to keep and find again, and their lists.

Revision ID: 023
Revises: 022
Create Date: 2026-10-23

One generic thing (title, details, fields, photo, place, its moment) in a list Echo
makes from what the user says. The photo, the conversation and the segment may be
deleted: the thing stays with its text (SET NULL).
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from pgvector.sqlalchemy import Vector
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "023"
down_revision: Union[str, None] = "022"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "saved_lists",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(80), nullable=False),
        sa.Column("latest_only", sa.Boolean(), nullable=False),
        sa.Column("keep_days", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_saved_lists_user_name", "saved_lists", ["user_id", "name"], unique=True)
    op.create_table(
        "saved_items",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("list_id", UUID(as_uuid=True), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("details", sa.Text(), nullable=True),
        sa.Column("fields", JSONB(), nullable=False),
        sa.Column("photo_id", UUID(as_uuid=True), nullable=True),
        sa.Column("place", JSONB(), nullable=True),
        sa.Column("people", JSONB(), nullable=False),
        sa.Column("conversation_id", UUID(as_uuid=True), nullable=True),
        sa.Column("segment_id", UUID(as_uuid=True), nullable=True),
        sa.Column("request_text", sa.Text(), nullable=True),
        sa.Column("source", sa.String(10), nullable=False),
        sa.Column("embedding", Vector(1536), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["list_id"], ["saved_lists.id"], name="fk_saved_items_list", ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["photo_id"], ["photos.id"], name="fk_saved_items_photo", ondelete="SET NULL"
        ),
        sa.ForeignKeyConstraint(
            ["conversation_id"],
            ["conversations.id"],
            name="fk_saved_items_conversation",
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["segment_id"], ["segments.id"], name="fk_saved_items_segment", ondelete="SET NULL"
        ),
    )
    op.create_index("ix_saved_items_user_id", "saved_items", ["user_id"])
    op.create_index("ix_saved_items_list_id", "saved_items", ["list_id"])


def downgrade() -> None:
    op.drop_index("ix_saved_items_list_id", table_name="saved_items")
    op.drop_index("ix_saved_items_user_id", table_name="saved_items")
    op.drop_table("saved_items")
    op.drop_index("ix_saved_lists_user_name", table_name="saved_lists")
    op.drop_table("saved_lists")
