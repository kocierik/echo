-- Second Brain AI Wearable — Full Database Schema
-- PostgreSQL 16+ with pgvector extension
-- Includes all migrations (001-004)

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- SEGMENTS: raw audio chunks received from the device
-- ============================================================
CREATE TABLE segments (
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
    -- Migration 002: idempotent ingest
    audio_hash VARCHAR(64),
    -- Migration 003: speaker detection
    audio_energy INTEGER,
    speaker VARCHAR(10) DEFAULT 'unknown'
);

CREATE INDEX idx_segments_user_recorded ON segments (user_id, recorded_at);
CREATE INDEX idx_segments_status ON segments (transcription_status) WHERE transcription_status != 'completed';
CREATE INDEX idx_segments_conversation ON segments (conversation_id);
CREATE UNIQUE INDEX idx_segments_audio_hash ON segments (audio_hash);

-- ============================================================
-- TRANSCRIPTIONS: STT output for each segment
-- ============================================================
CREATE TABLE transcriptions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    segment_id UUID NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    language TEXT NOT NULL DEFAULT 'it',
    confidence REAL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    stt_provider TEXT NOT NULL,
    stt_model TEXT NOT NULL
);

CREATE INDEX idx_transcriptions_segment ON transcriptions (segment_id);

-- ============================================================
-- CONVERSATIONS: logical grouping of segments
-- ============================================================
CREATE TABLE conversations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    title TEXT,
    summary TEXT,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    analysis_status TEXT NOT NULL DEFAULT 'pending'
);

CREATE INDEX idx_conversations_user_time ON conversations (user_id, started_at DESC);

-- FK from segments to conversations
ALTER TABLE segments ADD CONSTRAINT fk_segments_conversation
    FOREIGN KEY (conversation_id) REFERENCES conversations(id);

-- ============================================================
-- CHUNKS: fixed-size text chunks for RAG embedding
-- ============================================================
CREATE TABLE chunks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    token_count INTEGER NOT NULL,
    chunk_index INTEGER NOT NULL,
    embedding vector(1536),
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
    entity_type TEXT NOT NULL,
    name TEXT NOT NULL,
    content TEXT,
    metadata JSONB NOT NULL DEFAULT '{}',
    embedding vector(1536),
    source_transcription_id UUID REFERENCES transcriptions(id) ON DELETE SET NULL,
    conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_entities_user_type ON entities (user_id, entity_type);
CREATE INDEX idx_entities_name ON entities (user_id, name);
CREATE INDEX idx_entities_conversation ON entities (conversation_id);
CREATE INDEX idx_entities_embedding ON entities USING ivfflat (embedding vector_cosine_ops) WITH (lists = 50);

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
-- CHAT SESSIONS: persistent query history with the assistant
-- ============================================================
CREATE TABLE chat_sessions (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    title TEXT,
    messages JSONB NOT NULL DEFAULT '[]',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_chat_sessions_user ON chat_sessions (user_id, updated_at DESC);

-- ============================================================
-- API KEYS: simple auth for MVP
-- ============================================================
CREATE TABLE api_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    key_hash TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT 'default',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_api_keys_hash ON api_keys (key_hash);

-- ============================================================
-- QUERY FEEDBACK: user ratings on RAG answers (Migration 003)
-- ============================================================
CREATE TABLE query_feedback (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    session_id UUID NOT NULL,
    message_index INTEGER NOT NULL,
    rating VARCHAR(10) NOT NULL,
    comment TEXT,
    source_chunk_ids JSONB NOT NULL DEFAULT '[]',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_feedback_user ON query_feedback (user_id, created_at);
CREATE INDEX idx_feedback_chunks ON query_feedback USING gin (source_chunk_ids);

-- ============================================================
-- INTEGRATIONS: MCP integration store (Migration 004)
-- ============================================================
CREATE TABLE integrations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    provider VARCHAR(50) NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT false,
    config JSONB NOT NULL DEFAULT '{}',
    entity_types TEXT[] NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_integrations_user ON integrations (user_id);


-- ============================================================
-- RULES: user-defined automation rules (Migration 005)
-- ============================================================
CREATE TABLE rules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    name VARCHAR(200) NOT NULL,
    description TEXT,
    enabled BOOLEAN NOT NULL DEFAULT true,
    conditions JSONB NOT NULL DEFAULT '{}',
    actions JSONB NOT NULL DEFAULT '[]',
    trigger_count INTEGER NOT NULL DEFAULT 0,
    last_triggered_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_rules_user ON rules (user_id);
CREATE INDEX idx_rules_enabled ON rules (user_id, enabled) WHERE enabled = true;


-- ============================================================
-- ACTIONS: pending confirmations, audit log, chat session kind (Migration 007)
-- ============================================================
ALTER TABLE chat_sessions ADD COLUMN IF NOT EXISTS kind VARCHAR(10) NOT NULL DEFAULT 'chat';

CREATE TABLE IF NOT EXISTS pending_actions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    session_id UUID,
    source VARCHAR(10) NOT NULL,            -- chat | voice
    tool VARCHAR(200) NOT NULL,
    arguments JSONB NOT NULL DEFAULT '{}',
    summary TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending|executed|failed|cancelled|expired
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    resolved_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS ix_pending_actions_user_status ON pending_actions (user_id, status);

CREATE TABLE IF NOT EXISTS action_log (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    source VARCHAR(10) NOT NULL,            -- chat | voice
    toolkit VARCHAR(100) NOT NULL,
    tool VARCHAR(200) NOT NULL,
    arguments_summary TEXT NOT NULL DEFAULT '',
    outcome VARCHAR(10) NOT NULL,           -- ok | error
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_action_log_user_created ON action_log (user_id, created_at);
