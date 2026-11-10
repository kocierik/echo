"""Store facts about saved people and conversation topics.

Revision ID: 040
Revises: 039
Create Date: 2026-11-10
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "040"
down_revision: Union[str, None] = "039"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    tables = set(inspector.get_table_names())

    if "person_facts" not in tables:
        op.create_table(
            "person_facts",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, nullable=False),
            sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
            sa.Column("person_id", postgresql.UUID(as_uuid=True), nullable=False),
            sa.Column("text", sa.String(200), nullable=False),
            sa.Column("category", sa.String(20), nullable=False),
            sa.Column("quote", sa.Text(), nullable=False),
            sa.Column("segment_id", postgresql.UUID(as_uuid=True), nullable=True),
            sa.Column("conversation_id", postgresql.UUID(as_uuid=True), nullable=True),
            sa.Column("status", sa.String(12), nullable=False),
            sa.Column("superseded_by", postgresql.UUID(as_uuid=True), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
            sa.ForeignKeyConstraint(
                ["person_id"],
                ["entities.id"],
                name="fk_person_facts_person",
                ondelete="CASCADE",
            ),
            sa.ForeignKeyConstraint(
                ["segment_id"],
                ["segments.id"],
                name="fk_person_facts_segment",
                ondelete="SET NULL",
            ),
            sa.ForeignKeyConstraint(
                ["conversation_id"],
                ["conversations.id"],
                name="fk_person_facts_conversation",
                ondelete="SET NULL",
            ),
            sa.ForeignKeyConstraint(
                ["superseded_by"],
                ["person_facts.id"],
                name="fk_person_facts_superseded_by",
                ondelete="SET NULL",
            ),
        )
        indexes = set()
    else:
        indexes = {index["name"] for index in inspector.get_indexes("person_facts")}

    if "idx_person_facts_person_status" not in indexes:
        op.create_index(
            "idx_person_facts_person_status",
            "person_facts",
            ["person_id", "status"],
        )

    conversation_columns = {
        column["name"] for column in inspector.get_columns("conversations")
    }
    if "topics" not in conversation_columns:
        op.add_column(
            "conversations",
            sa.Column("topics", postgresql.ARRAY(sa.String(40)), nullable=True),
        )


def downgrade() -> None:
    inspector = sa_inspect(op.get_bind())
    tables = set(inspector.get_table_names())
    if "person_facts" in tables:
        op.drop_table("person_facts")

    if "conversations" in tables:
        columns = {column["name"] for column in inspector.get_columns("conversations")}
        if "topics" in columns:
            op.drop_column("conversations", "topics")
