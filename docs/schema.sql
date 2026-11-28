-- Reference only: the database is created by Alembic (`alembic upgrade head`).
-- Do not apply this file: it shows the schema at the head revision (047) for reading.
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
    -- pending | processing | completed | failed | deferred (past the plan's budget: the
    -- audio is kept until it is transcribed, services/plans.py)
    transcription_status TEXT NOT NULL DEFAULT 'pending',
    -- Migration 039: worker claim time, used to recover interrupted STT jobs
    transcription_started_at TIMESTAMPTZ,
    conversation_id UUID,
    -- Migration 002: idempotent ingest
    audio_hash VARCHAR(64),
    -- Migration 003: speaker detection
    audio_energy INTEGER,
    wake_heard BOOLEAN NOT NULL DEFAULT false,
    speaker VARCHAR(10) DEFAULT 'unknown'
);

CREATE INDEX idx_segments_user_recorded ON segments (user_id, recorded_at);
CREATE INDEX idx_segments_status ON segments (transcription_status) WHERE transcription_status != 'completed';
CREATE INDEX idx_segments_conversation ON segments (conversation_id);
CREATE UNIQUE INDEX idx_segments_user_audio_hash ON segments (user_id, audio_hash);

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

-- A transcript line translated into the user's language, kept once (Migration 027)
CREATE TABLE transcription_translations (
    id UUID PRIMARY KEY,
    transcription_id UUID NOT NULL REFERENCES transcriptions(id) ON DELETE CASCADE,
    language VARCHAR(10) NOT NULL,
    text TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT uq_transcription_translations_language UNIQUE (transcription_id, language)
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
    analysis_status TEXT NOT NULL DEFAULT 'pending',
    retranscribed_at TIMESTAMPTZ,            -- Migration 036
    topics VARCHAR(40)[]                      -- Migration 040
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
CREATE INDEX idx_chunks_embedding ON chunks USING hnsw (embedding vector_cosine_ops);  -- 035: was IVFFlat
-- Migration 042: a passage's words, for the search by the question's own words
ALTER TABLE chunks ADD COLUMN text_words tsvector GENERATED ALWAYS AS (to_tsvector('simple', text)) STORED;
CREATE INDEX idx_chunks_text_words ON chunks USING gin (text_words);

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
CREATE INDEX idx_entities_embedding ON entities USING hnsw (embedding vector_cosine_ops);  -- 035: was IVFFlat

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
    kind VARCHAR(10) NOT NULL DEFAULT 'chat',  -- Migration 007: chat | voice (the thread "Echo", 021)
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
    password_hash TEXT NOT NULL,         -- Argon2id; '' for an account made with Google
    google_subject VARCHAR(255) UNIQUE,  -- Google's id ("sub"), once signed in with Google (044)
    language VARCHAR(5) NOT NULL DEFAULT 'it',  -- spoken: transcription and dictation (016)
    name VARCHAR(100),                   -- the app's greeting; null until given (021)
    instructions TEXT,                   -- the user's own instructions to Echo (022)
    plan VARCHAR(20) NOT NULL DEFAULT 'free',  -- free | plus | unlimited (025)
    other_languages JSONB NOT NULL DEFAULT '[]',  -- other languages heard: ["en", "es"] (027); new accounts get the other of it/en (047)
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
ALTER TABLE segments ADD COLUMN voice_group INTEGER;          -- Migration 037: "Person 2"
ALTER TABLE transcriptions ADD COLUMN turns JSONB;         -- Migration 038: who said what

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
    mode VARCHAR(10) NOT NULL,         -- always | only_if | only_new (Migration 026)
    last_status VARCHAR(10),           -- reported | nothing | failed | skipped
    last_answer TEXT,
    source VARCHAR(10) NOT NULL,       -- chat | voice | catalog
    catalog_key VARCHAR(40),           -- the catalog entry it was added from (Migration 045)
    last_conversation_at TIMESTAMPTZ,  -- after_conversation: the last conversation run on (046)
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX ix_routines_user_id ON routines(user_id);
CREATE INDEX ix_routines_due ON routines(active, next_run_at);

-- One row per run of a routine (Migration 026), kept 90 days
CREATE TABLE routine_runs (
    id UUID PRIMARY KEY,
    routine_id UUID NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    ran_at TIMESTAMPTZ NOT NULL,
    status VARCHAR(10) NOT NULL,       -- reported | nothing | failed | skipped
    text TEXT,                         -- the answer in full; NULL when nothing or skipped
    sources JSONB NOT NULL,            -- [{title, url}]
    items JSONB NOT NULL               -- only_new: [{key, title, url}] reported this run
);
CREATE INDEX ix_routine_runs_routine_id ON routine_runs(routine_id);
CREATE INDEX ix_routine_runs_user_id ON routine_runs(user_id);
CREATE INDEX ix_routine_runs_user_ran ON routine_runs(user_id, ran_at);

-- ============================================================
-- SAVED: things the user asks Echo to keep and find again (Migration 023)
-- ============================================================
CREATE TABLE saved_lists (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    name VARCHAR(80) NOT NULL,         -- made by Echo: "Wines", "Your car"
    latest_only BOOLEAN NOT NULL,      -- saving another thing replaces it (the car)
    keep_days INTEGER,                 -- things deleted this many days after; NULL = kept
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL    -- the last thing saved or changed in it
);
CREATE UNIQUE INDEX ix_saved_lists_user_name ON saved_lists(user_id, name);

CREATE TABLE saved_items (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    list_id UUID NOT NULL,
    title TEXT NOT NULL,
    details TEXT,
    fields JSONB NOT NULL,             -- free: {"amount": 12.5, "vintage": "2019", ...}
    photo_id UUID,
    place JSONB,                       -- {latitude, longitude, accuracy_m, address}, asked for
    people JSONB NOT NULL,             -- [{name, id}] named in the request
    conversation_id UUID,
    segment_id UUID,                   -- a voice request's segment (its conversation, later)
    request_text TEXT,                 -- the request as said
    source VARCHAR(10) NOT NULL,       -- chat | voice
    embedding vector(1536),
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT fk_saved_items_list FOREIGN KEY (list_id) REFERENCES saved_lists(id) ON DELETE CASCADE,
    CONSTRAINT fk_saved_items_photo FOREIGN KEY (photo_id) REFERENCES photos(id) ON DELETE SET NULL,
    CONSTRAINT fk_saved_items_conversation FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE SET NULL,
    CONSTRAINT fk_saved_items_segment FOREIGN KEY (segment_id) REFERENCES segments(id) ON DELETE SET NULL
);
CREATE INDEX ix_saved_items_user_id ON saved_items(user_id);
CREATE INDEX ix_saved_items_list_id ON saved_items(list_id);

-- ============================================================
-- PLACES VISITED: the stays the phone noticed, when the user turned it on (Migration 024)
-- ============================================================
CREATE TABLE place_visits (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    key VARCHAR(80) NOT NULL,          -- the phone's id of the stay: sent open, then closed
    arrived_at TIMESTAMPTZ NOT NULL,
    left_at TIMESTAMPTZ,               -- NULL while still there
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    accuracy_m DOUBLE PRECISION,
    name TEXT,                         -- Apple's place name on iPhone, when there is one
    address TEXT,                      -- the phone's geocoder
    source VARCHAR(10) NOT NULL,       -- ios | android
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);
CREATE UNIQUE INDEX ix_place_visits_user_key ON place_visits(user_id, key);
CREATE INDEX ix_place_visits_user_arrived ON place_visits(user_id, arrived_at);

-- What Echo knows about the user: kept facts go into every answer (Migration 028)
CREATE TABLE user_facts (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    text VARCHAR(200) NOT NULL,
    status VARCHAR(10) NOT NULL,       -- kept | suggested
    source VARCHAR(15) NOT NULL,       -- you | echo | conversation
    conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX ix_user_facts_user_status ON user_facts(user_id, status);

-- The text of an uploaded file, never the file (Migration 028)
CREATE TABLE documents (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    title VARCHAR(255) NOT NULL,
    kind VARCHAR(10) NOT NULL,         -- pdf | docx | txt | md
    size_bytes INTEGER NOT NULL,
    status VARCHAR(12) NOT NULL,       -- processing | ready | failed
    error TEXT,
    text TEXT NOT NULL,
    pages INTEGER,
    word_count INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    raw BYTEA,                         -- the file until read, then NULL
    claimed_at TIMESTAMPTZ             -- a worker took it
);
CREATE INDEX ix_documents_user_id ON documents(user_id);
CREATE TABLE document_chunks (
    id UUID PRIMARY KEY,
    document_id UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    chunk_index INTEGER NOT NULL,
    text TEXT NOT NULL,
    embedding vector(1536)
);
CREATE INDEX ix_document_chunks_user_id ON document_chunks(user_id);
CREATE INDEX ix_document_chunks_document_id ON document_chunks(document_id);

-- Assistants: Echo for one part of the user's life (Migration 029)
CREATE TABLE assistants (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    name VARCHAR(40) NOT NULL,
    emoji VARCHAR(16) NOT NULL,
    instructions TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT '',     -- what it keeps about its topic
    document_ids JSONB NOT NULL DEFAULT '[]',  -- its documents; empty: all
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX ix_assistants_user_id ON assistants(user_id);
ALTER TABLE chat_sessions ADD COLUMN assistant_id UUID
    REFERENCES assistants(id) ON DELETE SET NULL;  -- 029
ALTER TABLE routines ADD COLUMN assistant_id UUID
    REFERENCES assistants(id) ON DELETE SET NULL;  -- 029

-- Firmware signed with the release key (Migration 030)
ALTER TABLE firmware_releases ADD COLUMN signature VARCHAR(128);  -- 030

-- Run tracking: one row per coordinator request or routine run, one per step (Migration 031)
CREATE TABLE agent_runs (
    id UUID PRIMARY KEY,
    correlation_id VARCHAR(64) NOT NULL,
    user_id UUID,
    source VARCHAR(10) NOT NULL,                -- chat | voice | routine
    status VARCHAR(20) NOT NULL DEFAULT 'running',
    plan_summary VARCHAR(200),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    tokens_in INTEGER NOT NULL DEFAULT 0,
    tokens_out INTEGER NOT NULL DEFAULT 0,
    cost_usd NUMERIC(12, 6) NOT NULL DEFAULT 0,
    cost_unknown BOOLEAN NOT NULL DEFAULT false,
    error_class VARCHAR(64),
    CONSTRAINT ck_agent_runs_ended_when_final CHECK ((status = 'running') = (ended_at IS NULL)),
    CONSTRAINT ck_agent_runs_ended_after_start CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX ix_agent_runs_user_started ON agent_runs(user_id, started_at);
CREATE INDEX ix_agent_runs_correlation_id ON agent_runs(correlation_id);
CREATE INDEX ix_agent_runs_started_at ON agent_runs(started_at);
CREATE TABLE agent_steps (
    id UUID PRIMARY KEY,
    run_id UUID NOT NULL,
    seq INTEGER NOT NULL,
    kind VARCHAR(20) NOT NULL,                  -- plan | delegation | llm_call | tool_call | synthesis
    agent_id VARCHAR(80),
    tool_name VARCHAR(120),
    model VARCHAR(80),
    tier VARCHAR(10),
    attempt INTEGER NOT NULL DEFAULT 1,
    started_at TIMESTAMPTZ NOT NULL,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    tokens_in INTEGER NOT NULL DEFAULT 0,
    tokens_out INTEGER NOT NULL DEFAULT 0,
    cost_usd NUMERIC(12, 6) NOT NULL DEFAULT 0,
    cost_unknown BOOLEAN NOT NULL DEFAULT false,
    status VARCHAR(10) NOT NULL,
    error_class VARCHAR(64),
    args_redacted JSONB,                        -- the tool's arguments, secrets removed
    action_log_id UUID,
    CONSTRAINT fk_agent_steps_run FOREIGN KEY (run_id) REFERENCES agent_runs(id) ON DELETE CASCADE,
    CONSTRAINT uq_agent_steps_run_seq UNIQUE (run_id, seq)
);

-- 033: the rows made by the example data (Profile → Example data); off deletes only them
CREATE TABLE demo_items (
    user_id UUID NOT NULL,
    kind VARCHAR(20) NOT NULL,  -- conversation | fact | saved_item | saved_list | place_visit
    item_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, kind, item_id)
);

-- 034: a day of the iPhone's Health app, sent by Apple's Shortcuts (Profile → Health)
CREATE TABLE health_days (
    user_id UUID NOT NULL,
    day DATE NOT NULL,
    sleep_minutes INTEGER,          -- asleep, the night that ended that morning
    steps INTEGER,
    distance_km DOUBLE PRECISION,
    active_kcal INTEGER,
    exercise_minutes INTEGER,
    resting_hr INTEGER,
    workouts TEXT,
    source VARCHAR(12) NOT NULL DEFAULT 'shortcuts',  -- shortcuts | demo
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, day)
);

-- Transcript-grounded facts about saved people (Migration 040; rejected_at added in 041)
CREATE TABLE person_facts (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    person_id UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    text VARCHAR(200) NOT NULL,
    category VARCHAR(20) NOT NULL,       -- work | family | home | interests | plans | other
    quote TEXT NOT NULL,
    segment_id UUID REFERENCES segments(id) ON DELETE SET NULL,
    conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
    status VARCHAR(12) NOT NULL,         -- current | superseded | rejected
    superseded_by UUID REFERENCES person_facts(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL,
    rejected_at TIMESTAMPTZ
);
CREATE INDEX idx_person_facts_person_status ON person_facts (person_id, status);
