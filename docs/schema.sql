-- Reference only: the database is created by Alembic (`alembic upgrade head`).
-- Do not apply this file: it shows the schema at the head revision (013) for reading.
--
-- Second Brain AI Wearable — Full Database Schema
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
    recorded_at TIMESTAMPTZ NOT NULL,
    duration_ms INTEGER NOT NULL,
    -- Migration 006: NULL once the audio file is deleted by retention
    audio_path TEXT,
    audio_size_bytes INTEGER,
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
    -- Migration 006: speaker detected by STT diarization
    speaker_label VARCHAR(10),
    language TEXT NOT NULL DEFAULT 'it',
    confidence REAL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    stt_provider TEXT NOT NULL,
    stt_model TEXT NOT NULL
);

CREATE INDEX idx_transcriptions_segment ON transcriptions (segment_id);

-- ============================================================
-- TRANSCRIPTION EDITS: audit of manual corrections (Migration 006)
-- ============================================================
CREATE TABLE transcription_edits (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    transcription_id UUID NOT NULL,
    user_id UUID NOT NULL,
    old_text TEXT NOT NULL,
    new_text TEXT NOT NULL,
    old_speaker_label VARCHAR(10),
    new_speaker_label VARCHAR(10),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_transcription_edits_transcription_id_transcriptions
        FOREIGN KEY (transcription_id) REFERENCES transcriptions(id) ON DELETE CASCADE
);

CREATE INDEX ix_transcription_edits_transcription_id ON transcription_edits (transcription_id);
CREATE INDEX ix_transcription_edits_user_id ON transcription_edits (user_id);

-- ============================================================
-- CONVERSATIONS: logical grouping of segments
-- ============================================================
CREATE TABLE conversations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    title TEXT,
    summary TEXT,
    emoji VARCHAR(16),                       -- Migration 009
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    analysis_status TEXT NOT NULL DEFAULT 'pending'
);

CREATE INDEX idx_conversations_user_time ON conversations (user_id, started_at DESC);

-- FK from segments to conversations (Migration 006: deleting a conversation deletes its segments)
ALTER TABLE segments ADD CONSTRAINT fk_segments_conversation_id_conversations
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE;

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
    photo_id UUID,  -- Migration 011: a photo's description (FK below, after photos)
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
    -- Migration 006: deleting a conversation deletes its entities
    conversation_id UUID CONSTRAINT fk_entities_conversation_id_conversations
        REFERENCES conversations(id) ON DELETE CASCADE,
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
    kind VARCHAR(10) NOT NULL DEFAULT 'chat',  -- Migration 007: chat | voice
    messages JSONB NOT NULL DEFAULT '[]',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_chat_sessions_user ON chat_sessions (user_id, updated_at DESC);

-- Migration 011: photos from the wearable camera (the wearable keeps nothing)
CREATE TABLE photos (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'requested',  -- requested | received | done | failed
    source VARCHAR(10) NOT NULL,                      -- voice | app
    question TEXT,
    chat_session_id UUID REFERENCES chat_sessions(id) ON DELETE CASCADE,
    conversation_id UUID REFERENCES conversations(id) ON DELETE CASCADE,
    captured_at TIMESTAMPTZ,
    image BYTEA,                                      -- JPEG
    image_sha256 VARCHAR(64),
    size_bytes INTEGER,
    description TEXT,                                 -- for memory search
    answer TEXT,                                      -- shown in the chat
    error VARCHAR(40),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_photos_user_id ON photos (user_id);
CREATE INDEX ix_photos_conversation_id ON photos (conversation_id);
CREATE INDEX ix_photos_status ON photos (status);
ALTER TABLE chunks ADD FOREIGN KEY (photo_id) REFERENCES photos(id) ON DELETE CASCADE;
CREATE INDEX ix_chunks_photo_id ON chunks (photo_id);

-- ============================================================
-- API KEYS: simple auth for MVP
-- ============================================================
CREATE TABLE api_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    key_hash TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT 'default',
    platform VARCHAR(20),  -- "ios"/"android" for keys given at sign-in (Migration 015)
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ,
    scope VARCHAR(10) NOT NULL DEFAULT 'full'  -- full: REST API; read: connected apps, MCP only (018)
);

CREATE UNIQUE INDEX idx_api_keys_hash ON api_keys (key_hash);

-- ============================================================
-- USERS: accounts; signing in gives a phone its own API key (Migration 015)
-- ============================================================
CREATE TABLE users (
    id UUID PRIMARY KEY,
    email VARCHAR(320) NOT NULL UNIQUE,  -- stored lower-cased
    password_hash TEXT NOT NULL,         -- Argon2id
    language VARCHAR(5) NOT NULL DEFAULT 'it',  -- spoken: transcription and dictation (016)
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

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
-- ACTIONS: pending confirmations and audit log (Migration 007)
-- (Migration 008 dropped the old rules and integrations tables.)
-- ============================================================
CREATE TABLE pending_actions (
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

CREATE INDEX ix_pending_actions_user_status ON pending_actions (user_id, status);

CREATE TABLE action_log (
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

CREATE INDEX ix_action_log_user_created ON action_log (user_id, created_at);

CREATE TABLE entity_mentions (                -- Migration 010
    id UUID PRIMARY KEY,
    entity_id UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    transcription_id UUID REFERENCES transcriptions(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (entity_id, conversation_id)
);
CREATE INDEX ix_entity_mentions_entity_id ON entity_mentions (entity_id);
CREATE INDEX ix_entity_mentions_conversation_id ON entity_mentions (conversation_id);

-- Migration 012: weekly summaries (Monday to Sunday, user's timezone)
CREATE TABLE weekly_digests (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    week_start DATE NOT NULL,                         -- a Monday
    summary TEXT NOT NULL,
    highlights JSONB NOT NULL DEFAULT '[]',
    people JSONB NOT NULL DEFAULT '[]',               -- [{"name", "conversations"}]
    conversation_count INTEGER NOT NULL DEFAULT 0,
    tasks_created INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, week_start)
);

CREATE INDEX ix_weekly_digests_user_id ON weekly_digests (user_id);

-- Migration 013: voice fingerprints (biometric: made only by the user, deletable)
CREATE TABLE voice_profiles (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    name VARCHAR(200) NOT NULL,
    is_self BOOLEAN NOT NULL DEFAULT false,
    person_id UUID REFERENCES entities(id) ON DELETE SET NULL,
    embedding vector(256) NOT NULL,                   -- normalized mean of confirmed segments
    sample_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_voice_profiles_user_id ON voice_profiles (user_id);
CREATE UNIQUE INDEX uq_voice_profiles_self ON voice_profiles (user_id) WHERE is_self;
ALTER TABLE segments ADD COLUMN voice_embedding vector(256);
ALTER TABLE segments ADD COLUMN voice_profile_id UUID REFERENCES voice_profiles(id) ON DELETE SET NULL;
ALTER TABLE segments ADD COLUMN voice_similarity FLOAT;
ALTER TABLE segments ADD COLUMN voice_match VARCHAR(10);      -- auto | suggested | confirmed

-- ============================================================
-- FIRMWARE RELEASES: wearable firmware for updates over BLE (Migration 014)
-- ============================================================
CREATE TABLE firmware_releases (
    id UUID PRIMARY KEY,
    version VARCHAR(20) NOT NULL UNIQUE,
    size_bytes INTEGER NOT NULL,
    sha256 VARCHAR(64) NOT NULL,
    notes TEXT,
    image BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ============================================================
-- LLM USAGE: model work per user and day, for the cost of Echo (Migration 017)
-- ============================================================
CREATE TABLE llm_usage (
    id UUID PRIMARY KEY,
    user_id UUID,                 -- null: work no one owned (logged)
    day DATE NOT NULL,            -- UTC
    kind VARCHAR(32) NOT NULL,    -- stt, embedding, llm_analysis, llm_query, llm_intent, llm_vision, voice_embedding
    model VARCHAR(100) NOT NULL,
    calls INT NOT NULL DEFAULT 0,
    input_units BIGINT NOT NULL DEFAULT 0,   -- tokens; seconds of audio for stt
    output_units BIGINT NOT NULL DEFAULT 0,
    cached_units BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT uq_llm_usage_day UNIQUE NULLS NOT DISTINCT (user_id, day, kind, model)
);


-- ============================================================
-- MCP CALLS: tool calls by connected apps (Migration 019)
-- ============================================================
CREATE TABLE mcp_calls (
    id UUID PRIMARY KEY,
    api_key_id UUID NOT NULL REFERENCES api_keys(id) ON DELETE CASCADE,
    tool VARCHAR(40) NOT NULL,
    summary VARCHAR(200) NOT NULL DEFAULT '',  -- redacted: tool and argument names
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX ix_mcp_calls_api_key_id ON mcp_calls(api_key_id);

-- ============================================================
-- ROUTINES: what Echo does on its own at a time (Migration 020)
-- ============================================================
CREATE TABLE routines (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    instruction TEXT NOT NULL,         -- the request in the user's words
    schedule JSONB NOT NULL,           -- {kind, time, days?, day_of_month?}
    timezone VARCHAR(64) NOT NULL,     -- the schedule's wall times are read here
    active BOOLEAN NOT NULL,
    next_run_at TIMESTAMPTZ NOT NULL,
    last_run_at TIMESTAMPTZ,
    last_status VARCHAR(10),           -- ok | failed | skipped
    last_answer TEXT,
    source VARCHAR(10) NOT NULL,       -- chat | voice
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX ix_routines_user_id ON routines(user_id);
CREATE INDEX ix_routines_due ON routines(active, next_run_at);
