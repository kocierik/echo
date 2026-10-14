"""Baseline schema: the tables as they were at revision 001.

Revision ID: 001
Revises: None
Create Date: 2026-07-25

A fresh database is created by `alembic upgrade head` alone: this revision creates the
extensions and the baseline tables, 002+ add the rest. Tables that already exist are
skipped (with their indexes), so databases created earlier from docs/schema.sql, stamped
or not, are left as they are.
"""
from typing import Sequence, Union

from alembic import op
from sqlalchemy import inspect as sa_inspect

# revision identifiers, used by Alembic.
revision: str = "001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

EXTENSIONS = (
    'CREATE EXTENSION IF NOT EXISTS "uuid-ossp"',
    "CREATE EXTENSION IF NOT EXISTS vector",
)

# (table, CREATE TABLE, its indexes), in dependency order. Later revisions add:
# 002 segments.audio_hash, 003 segments.audio_energy/speaker and query_feedback,
# 006 nullable segments audio storage, transcriptions.speaker_label,
# transcription_edits and the CASCADE conversation foreign keys, 007 chat_sessions.kind,
# pending_actions and action_log.
TABLES: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    (
        "conversations",
        """CREATE TABLE conversations (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            user_id UUID NOT NULL,
            title TEXT,
            summary TEXT,
            started_at TIMESTAMPTZ NOT NULL,
            ended_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            analysis_status TEXT NOT NULL DEFAULT 'pending'
        )""",
        (
            "CREATE INDEX idx_conversations_user_time "
            "ON conversations (user_id, started_at DESC)",
        ),
    ),
    (
        "segments",
        """CREATE TABLE segments (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            user_id UUID NOT NULL,
            received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            recorded_at TIMESTAMPTZ NOT NULL,
            duration_ms INTEGER NOT NULL,
            audio_path TEXT NOT NULL,
            audio_size_bytes INTEGER NOT NULL,
            silence_before_ms INTEGER,
            transcription_status TEXT NOT NULL DEFAULT 'pending',
            conversation_id UUID,
            CONSTRAINT fk_segments_conversation FOREIGN KEY (conversation_id)
                REFERENCES conversations(id)
        )""",
        (
            "CREATE INDEX idx_segments_user_recorded ON segments (user_id, recorded_at)",
            "CREATE INDEX idx_segments_status ON segments (transcription_status) "
            "WHERE transcription_status != 'completed'",
            "CREATE INDEX idx_segments_conversation ON segments (conversation_id)",
        ),
    ),
    (
        "transcriptions",
        """CREATE TABLE transcriptions (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            segment_id UUID NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
            text TEXT NOT NULL,
            language TEXT NOT NULL DEFAULT 'it',
            confidence REAL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            stt_provider TEXT NOT NULL,
            stt_model TEXT NOT NULL
        )""",
        ("CREATE INDEX idx_transcriptions_segment ON transcriptions (segment_id)",),
    ),
    (
        "chunks",
        """CREATE TABLE chunks (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            text TEXT NOT NULL,
            token_count INTEGER NOT NULL,
            chunk_index INTEGER NOT NULL,
            embedding vector(1536),
            created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )""",
        (
            "CREATE INDEX idx_chunks_conversation ON chunks (conversation_id)",
            "CREATE INDEX idx_chunks_embedding ON chunks "
            "USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)",
        ),
    ),
    (
        "entities",
        """CREATE TABLE entities (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            user_id UUID NOT NULL,
            entity_type TEXT NOT NULL,
            name TEXT NOT NULL,
            content TEXT,
            metadata JSONB NOT NULL DEFAULT '{}',
            embedding vector(1536),
            source_transcription_id UUID REFERENCES transcriptions(id) ON DELETE SET NULL,
            conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )""",
        (
            "CREATE INDEX idx_entities_user_type ON entities (user_id, entity_type)",
            "CREATE INDEX idx_entities_name ON entities (user_id, name)",
            "CREATE INDEX idx_entities_conversation ON entities (conversation_id)",
            "CREATE INDEX idx_entities_embedding ON entities "
            "USING ivfflat (embedding vector_cosine_ops) WITH (lists = 50)",
        ),
    ),
    (
        "digests",
        """CREATE TABLE digests (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            user_id UUID NOT NULL,
            digest_date DATE NOT NULL,
            summary TEXT NOT NULL,
            people JSONB NOT NULL DEFAULT '[]',
            tasks JSONB NOT NULL DEFAULT '[]',
            ideas JSONB NOT NULL DEFAULT '[]',
            events JSONB NOT NULL DEFAULT '[]',
            conversation_count INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )""",
        ("CREATE UNIQUE INDEX idx_digests_user_date ON digests (user_id, digest_date)",),
    ),
    (
        "chat_sessions",
        """CREATE TABLE chat_sessions (
            id UUID PRIMARY KEY,
            user_id UUID NOT NULL,
            title TEXT,
            messages JSONB NOT NULL DEFAULT '[]',
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )""",
        (
            "CREATE INDEX idx_chat_sessions_user ON chat_sessions (user_id, updated_at DESC)",
        ),
    ),
    (
        "api_keys",
        """CREATE TABLE api_keys (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            user_id UUID NOT NULL,
            key_hash TEXT NOT NULL,
            name TEXT NOT NULL DEFAULT 'default',
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            last_used_at TIMESTAMPTZ
        )""",
        ("CREATE UNIQUE INDEX idx_api_keys_hash ON api_keys (key_hash)",),
    ),
)


def upgrade() -> None:
    existing = set(sa_inspect(op.get_bind()).get_table_names())
    missing = [entry for entry in TABLES if entry[0] not in existing]
    if not missing:
        return
    for statement in EXTENSIONS:
        op.execute(statement)
    for _table, create_table, indexes in missing:
        op.execute(create_table)
        for create_index in indexes:
            op.execute(create_index)


def downgrade() -> None:
    """Cannot downgrade baseline — would need to drop entire schema."""
    raise RuntimeError("Cannot downgrade past baseline. Drop the database manually if needed.")
