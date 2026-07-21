-- Second Brain AI Wearable — MVP Database Schema
-- PostgreSQL 16+ with pgvector extension

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- SEGMENTS: raw audio chunks received from the device
-- ============================================================
CREATE TABLE segments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    recorded_at TIMESTAMPTZ NOT NULL,           -- device-reported timestamp
    duration_ms INTEGER NOT NULL,               -- audio duration in milliseconds
    audio_path TEXT NOT NULL,                    -- path to stored ADPCM file
    audio_size_bytes INTEGER NOT NULL,
    silence_before_ms INTEGER,                  -- silence gap before this segment (for timeout grouping)
    transcription_status TEXT NOT NULL DEFAULT 'pending'  -- pending | processing | completed | failed
);

CREATE INDEX idx_segments_user_recorded ON segments (user_id, recorded_at);
CREATE INDEX idx_segments_status ON segments (transcription_status) WHERE transcription_status != 'completed';

-- ============================================================
-- TRANSCRIPTIONS: STT output for each segment
-- ============================================================
CREATE TABLE transcriptions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    segment_id UUID NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    language TEXT NOT NULL DEFAULT 'it',
    confidence REAL,                            -- overall confidence score from STT
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    stt_provider TEXT NOT NULL,                 -- e.g. 'openai_whisper'
    stt_model TEXT NOT NULL                     -- e.g. 'whisper-1'
);

CREATE INDEX idx_transcriptions_segment ON transcriptions (segment_id);

-- ============================================================
-- CONVERSATIONS: logical grouping of segments
-- ============================================================
CREATE TABLE conversations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    title TEXT,                                  -- LLM-generated title
    summary TEXT,                                -- LLM-generated summary
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    analysis_status TEXT NOT NULL DEFAULT 'pending'  -- pending | completed
);

CREATE INDEX idx_conversations_user_time ON conversations (user_id, started_at DESC);

-- Link segments to conversations (a segment belongs to exactly one conversation)
ALTER TABLE segments ADD COLUMN conversation_id UUID REFERENCES conversations(id);
CREATE INDEX idx_segments_conversation ON segments (conversation_id);

-- ============================================================
-- CHUNKS: fixed-size text chunks for RAG embedding
-- ============================================================
CREATE TABLE chunks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    token_count INTEGER NOT NULL,
    chunk_index INTEGER NOT NULL,               -- order within the conversation
    embedding vector(1536),                     -- OpenAI text-embedding-3-small
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_chunks_conversation ON chunks (conversation_id);
CREATE INDEX idx_chunks_embedding ON chunks USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ============================================================
-- ENTITIES: structured knowledge extracted by LLM
-- ============================================================
CREATE TABLE entities (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    entity_type TEXT NOT NULL,                  -- 'person' | 'task' | 'idea' | 'event' | 'note'
    name TEXT NOT NULL,                         -- canonical name (e.g. "Marco", "Comprare latte")
    content TEXT,                               -- additional detail / description
    metadata JSONB NOT NULL DEFAULT '{}',       -- type-specific fields (see below)
    source_transcription_id UUID REFERENCES transcriptions(id) ON DELETE SET NULL,
    conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- metadata examples by type:
-- person:  {"role": "collega", "notes": "lavora in marketing"}
-- task:    {"done": false, "due_date": "2026-08-01", "priority": "high"}
-- idea:    {"tags": ["wearable", "AI"]}
-- event:   {"event_date": "2026-09-15", "location": "Milano"}
-- note:    {"tags": ["generico"]}

CREATE INDEX idx_entities_user_type ON entities (user_id, entity_type);
CREATE INDEX idx_entities_name ON entities (user_id, name);
CREATE INDEX idx_entities_conversation ON entities (conversation_id);

-- ============================================================
-- AUDIO RETENTION: cleanup policy (30 days)
-- ============================================================
-- A scheduled job deletes segments.audio_path files and NULLs the column
-- for segments older than 30 days. The transcription and entities remain.

-- ============================================================
-- DIGESTS: daily summaries generated automatically
-- ============================================================
CREATE TABLE digests (
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
);

CREATE UNIQUE INDEX idx_digests_user_date ON digests (user_id, digest_date);

-- ============================================================
-- API KEYS: simple auth for MVP
-- ============================================================
CREATE TABLE api_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    key_hash TEXT NOT NULL,                     -- SHA-256 of the API key
    name TEXT NOT NULL DEFAULT 'default',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_api_keys_hash ON api_keys (key_hash);
