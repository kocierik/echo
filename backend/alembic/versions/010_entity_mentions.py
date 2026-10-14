"""Record every conversation an entity is mentioned in.

Revision ID: 010
Revises: 009
Create Date: 2026-10-14

Entities are consolidated across conversations, so entities.conversation_id only
names the latest one. entity_mentions keeps them all; existing entities get one
mention for the conversation they point at.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy import inspect as sa_inspect
from sqlalchemy.dialects.postgresql import UUID

revision: str = "010"
down_revision: Union[str, None] = "009"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    if "entity_mentions" in sa_inspect(op.get_bind()).get_table_names():
        return
    op.create_table(
        "entity_mentions",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "entity_id",
            UUID(as_uuid=True),
            sa.ForeignKey("entities.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "conversation_id",
            UUID(as_uuid=True),
            sa.ForeignKey("conversations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "transcription_id",
            UUID(as_uuid=True),
            sa.ForeignKey("transcriptions.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.UniqueConstraint("entity_id", "conversation_id"),
    )
    op.create_index("ix_entity_mentions_entity_id", "entity_mentions", ["entity_id"])
    op.create_index(
        "ix_entity_mentions_conversation_id", "entity_mentions", ["conversation_id"]
    )
    op.execute(
        """
        INSERT INTO entity_mentions (id, entity_id, conversation_id, transcription_id, created_at)
        SELECT gen_random_uuid(), id, conversation_id, source_transcription_id, created_at
        FROM entities
        WHERE conversation_id IS NOT NULL
        """
    )


def downgrade() -> None:
    op.drop_table("entity_mentions")
