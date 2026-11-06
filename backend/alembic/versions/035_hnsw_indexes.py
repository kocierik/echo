"""The vector indexes of chunks and entities as HNSW instead of IVFFlat.

Revision ID: 035
Revises: 034
Create Date: 2026-11-06

The IVFFlat indexes were made by the baseline on empty tables: IVFFlat learns its lists
from the rows there when it is built, so these lists were arbitrary. Once Postgres chose
the index over reading the table (it does as the table grows, or when its statistics
say so), a search looked in one arbitrary list and missed what it was looking for: memory
answers lost their conversations (and the CI failed now and then on the same queries).
HNSW needs no training and stays accurate as rows come and go. Same names, same operator.
"""

from typing import Sequence, Union

from alembic import op

revision: str = "035"
down_revision: Union[str, None] = "034"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    for name, table in (("idx_chunks_embedding", "chunks"), ("idx_entities_embedding", "entities")):
        op.execute(f"DROP INDEX IF EXISTS {name}")
        op.execute(f"CREATE INDEX {name} ON {table} USING hnsw (embedding vector_cosine_ops)")


def downgrade() -> None:
    for name, table, lists in (
        ("idx_chunks_embedding", "chunks", 100),
        ("idx_entities_embedding", "entities", 50),
    ):
        op.execute(f"DROP INDEX IF EXISTS {name}")
        op.execute(
            f"CREATE INDEX {name} ON {table} "
            f"USING ivfflat (embedding vector_cosine_ops) WITH (lists = {lists})"
        )
