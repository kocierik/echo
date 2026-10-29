"""What Echo knows about the user, and the user's documents.

Revision ID: 028
Revises: 027
Create Date: 2026-10-29

user_facts: one sentence each, kept (in every answer) or suggested (waiting for the user).
documents: the text of an uploaded file (never the file), and its chunks for the memory.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from pgvector.sqlalchemy import Vector
from sqlalchemy.dialects.postgresql import UUID

revision: str = "028"
down_revision: Union[str, None] = "027"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "user_facts",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("text", sa.String(200), nullable=False),
        # "kept" (used in answers) | "suggested" (waiting for Keep or Discard)
        sa.Column("status", sa.String(10), nullable=False),
        # "you" (the app) | "echo" (asked by voice or chat) | "conversation" (suggested)
        sa.Column("source", sa.String(15), nullable=False),
        sa.Column("conversation_id", UUID(as_uuid=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["conversation_id"], ["conversations.id"],
            name="fk_user_facts_conversation", ondelete="SET NULL",
        ),
    )
    op.create_index("ix_user_facts_user_status", "user_facts", ["user_id", "status"])
    op.create_table(
        "documents",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("title", sa.String(255), nullable=False),
        sa.Column("kind", sa.String(10), nullable=False),
        sa.Column("size_bytes", sa.Integer, nullable=False),
        # "processing" | "ready" | "failed"
        sa.Column("status", sa.String(12), nullable=False),
        sa.Column("error", sa.Text, nullable=True),
        sa.Column("text", sa.Text, nullable=False),
        sa.Column("pages", sa.Integer, nullable=True),
        sa.Column("word_count", sa.Integer, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_documents_user_id", "documents", ["user_id"])
    op.create_table(
        "document_chunks",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("document_id", UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("chunk_index", sa.Integer, nullable=False),
        sa.Column("text", sa.Text, nullable=False),
        sa.Column("embedding", Vector(1536), nullable=True),
        sa.ForeignKeyConstraint(
            ["document_id"], ["documents.id"],
            name="fk_document_chunks_document", ondelete="CASCADE",
        ),
    )
    op.create_index("ix_document_chunks_user_id", "document_chunks", ["user_id"])
    op.create_index("ix_document_chunks_document_id", "document_chunks", ["document_id"])


def downgrade() -> None:
    op.drop_table("document_chunks")
    op.drop_table("documents")
    op.drop_table("user_facts")
