# Echo — Second Brain AI Wearable

An open-source wearable device that continuously listens for speech, transcribes it, extracts structured knowledge, and builds a persistent personal memory queryable in natural language.

## Architecture

```
┌─────────────┐     HTTP POST      ┌─────────────────────────────┐
│   Wearable  │ ──── (ADPCM) ────▶ │         FastAPI (api)       │
│  ESP32-S3   │                     │   POST /api/segments        │
└─────────────┘                     │   POST /api/query           │
                                    └──────────┬──────────────────┘
                                               │ Redis queue
                                    ┌──────────▼──────────────────┐
                                    │     Background Worker        │
                                    │  STT → Analysis → Embeddings │
                                    │  + Retry + Dead Letter Queue │
                                    │  + Daily Digest generation   │
                                    └──────────┬──────────────────┘
                                               │
                                    ┌──────────▼──────────────────┐
                                    │   PostgreSQL + pgvector      │
                                    │   (segments, transcriptions, │
                                    │    conversations, chunks,    │
                                    │    entities, digests,        │
                                    │    chat_sessions)            │
                                    └─────────────────────────────┘
```

## Quick Start

### Prerequisites

- Docker & Docker Compose
- OpenAI API key

### 1. Clone and configure

```bash
git clone <repo-url> echo
cd echo
cp .env.example .env
# Edit .env and add your OPENAI_API_KEY
```

### 2. Start all services

```bash
docker compose up --build
```

This starts:
- **API** on http://localhost:8000 (FastAPI + Web UI)
- **Worker** (background STT + analysis + daily digest)
- **PostgreSQL** with pgvector on port 5432
- **Redis** on port 6379

### 3. Initialize the database

On first run, apply the schema:

```bash
docker compose exec -T postgres psql -U echo -d echo < docs/schema.sql
docker compose exec api python -m alembic stamp head
```

The `alembic stamp head` tells Alembic that your database already has the current schema, so future migrations will apply incrementally.

To apply new migrations after a `git pull`:

```bash
docker compose exec api python -m alembic upgrade head
```

To reset the database (drops all data):

```bash
docker compose exec -T postgres psql -U echo -d echo -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
docker compose exec -T postgres psql -U echo -d echo < docs/schema.sql
docker compose exec api python -m alembic stamp head
```

### 4. Create an API key

```bash
docker compose exec -T postgres psql -U echo -d echo -c "
INSERT INTO api_keys (user_id, key_hash, name) VALUES (
    'a0000000-0000-0000-0000-000000000001',
    encode(sha256('my-secret-key'::bytea), 'hex'),
    'default'
);"
```

Your API key is `my-secret-key`. Use it in the web UI or in the `X-API-Key` header.

### 5. Use the Web UI

Open http://localhost:8000 and enter your API key. Features:
- **Chat tab**: Ask questions about your memory with follow-up support
- **Audio tab**: Browse transcribed conversations from the device
- **Session history**: All chats are saved and can be resumed
- **Temporal filters**: Ask "cosa è successo ieri?" and it auto-filters by date

### 6. Admin Dashboard

Open http://localhost:8000/admin.html for system monitoring:
- Live stats (segments, transcriptions, entities, storage)
- Health check (PostgreSQL + Redis)
- Dead letter queue viewer with retry

### 7. Send audio from the device

The wearable sends audio segments via HTTP POST:

```bash
curl -X POST http://localhost:8000/api/segments \
  -H "X-API-Key: my-secret-key" \
  -H "X-Recorded-At: 2026-07-19T10:30:00Z" \
  -H "X-Duration-Ms: 5000" \
  -F "audio=@segment.adpcm"
```

## Project Structure

```
echo/
├── CONTEXT.md                    # Domain glossary
├── docker-compose.yml
├── .env.example
├── docs/
│   ├── schema.sql               # Database schema
│   ├── ROADMAP.md               # Feature roadmap
│   ├── DEVELOPMENT.md           # Dev setup guide
│   └── adr/                     # Architectural Decision Records
├── backend/
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── static/
│   │   ├── index.html           # Web UI (chat + sessions)
│   │   └── admin.html           # Admin dashboard
│   ├── tests/
│   │   ├── test_adpcm_decoder.py
│   │   ├── test_temporal.py     # Temporal filter tests
│   │   └── test_chunking.py     # Sentence chunking tests
│   └── app/
│       ├── main.py              # FastAPI app + lifespan
│       ├── core/
│       │   ├── config.py        # Settings (env vars)
│       │   ├── database.py      # Async SQLAlchemy
│       │   └── auth.py          # API key auth
│       ├── models/
│       │   ├── segment.py
│       │   ├── transcription.py
│       │   ├── conversation.py
│       │   ├── chunk.py
│       │   ├── entity.py        # + vector embedding
│       │   ├── digest.py        # Daily summaries
│       │   ├── chat_session.py  # Persistent chat history
│       │   └── api_key.py
│       ├── routers/
│       │   ├── segments.py      # POST /api/segments
│       │   ├── query.py         # POST /api/query (RAG + sessions)
│       │   ├── conversations.py # Audio conversations
│       │   ├── entities.py      # Knowledge entities
│       │   ├── digest.py        # Daily digest
│       │   ├── chat_sessions.py # Chat history CRUD
│       │   └── admin.py         # Dead letter queue
│       ├── services/
│       │   ├── temporal.py      # NLP date extraction
│       │   ├── chunking.py      # Sentence-aware chunking
│       │   ├── deduplication.py # Entity dedup
│       │   ├── adpcm_decoder.py
│       │   ├── stt_base.py / stt_openai.py
│       │   ├── llm_base.py / llm_openai.py
│       │   └── embedding_base.py / embedding_openai.py
│       └── workers/
│           ├── main.py          # Worker entry (STT + analysis)
│           ├── retry.py         # Exponential backoff utility
│           ├── digest.py        # Daily digest generation
│           └── retention.py     # Audio file cleanup
├── firmware/                    # ESP32-S3 Arduino code
└── simulator/                   # Device simulator (Python)
```

## API Reference

### POST /api/segments

Receive an audio segment from the device.

**Headers:**
- `X-API-Key`: API key (required)
- `X-Recorded-At`: ISO 8601 timestamp
- `X-Duration-Ms`: Duration in milliseconds
- `X-Silence-Before-Ms`: Silence before segment (optional)

**Body:** Multipart form with `audio` file (ADPCM, max 5MB)

### POST /api/query

Query personal memory with natural language. Supports multi-turn follow-up and automatic temporal filtering.

**Body:**
```json
{
  "question": "Cosa mi ha detto Marco ieri?",
  "top_k": 5,
  "session_id": "optional-uuid-for-follow-up",
  "date_from": "2026-07-20T00:00:00Z",
  "date_to": "2026-07-20T23:59:59Z"
}
```

**Response:**
```json
{
  "answer": "Marco ti ha consigliato di...",
  "sources": [{"conversation_id": "uuid", "text": "...", "similarity": 0.89}],
  "session_id": "uuid-to-use-for-follow-up",
  "date_filter": {"from": "2026-07-20T00:00:00+00:00", "to": "2026-07-20T23:59:59+00:00"}
}
```

### GET /api/chat-sessions

List saved chat sessions (most recent first).

### GET /api/chat-sessions/{id}

Get full message history for a session.

### DELETE /api/chat-sessions/{id}

Delete a chat session.

### GET /api/digest?days=7

List recent daily digests.

### GET /api/digest/{date}

Get a specific day's digest (people, tasks, ideas, events, summary).

### POST /api/digest/{date}

Manually trigger digest generation for a date.

### GET /api/admin/dead-letter

List failed segments in the dead letter queue.

### POST /api/admin/dead-letter/retry

Retry all failed segments.

### GET /health

Health check (PostgreSQL + Redis connectivity).

### GET /api/stats

System statistics (counts + storage usage).

## Key Features

- **Temporal filtering**: Ask "ieri", "questa settimana", "3 giorni fa" — auto-detected
- **Multi-turn follow-up**: Continue conversations with session context
- **Daily digest**: Automatic daily summary at 21:00 UTC
- **Entity embeddings**: Semantic search on extracted knowledge
- **Sentence-aware chunking**: Never cuts concepts mid-sentence
- **Retry + dead letter**: Resilient worker with exponential backoff
- **Graceful shutdown**: No data loss on Docker restart

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgresql+asyncpg://echo:echo@localhost:5432/echo` | PostgreSQL connection |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection |
| `OPENAI_API_KEY` | — | OpenAI API key (required) |
| `AUDIO_STORAGE_PATH` | `/data/audio` | Audio file storage |
| `AUDIO_RETENTION_DAYS` | `30` | Days to keep raw audio |
| `STT_LANGUAGE` | `it` | Primary language for STT |
| `LLM_ANALYSIS_MODEL` | `gpt-4o-mini` | Model for entity extraction |
| `LLM_QUERY_MODEL` | `gpt-4o` | Model for RAG answers |
| `CHUNK_SIZE_TOKENS` | `500` | Chunk size for embedding |
| `CHUNK_OVERLAP_TOKENS` | `50` | Overlap between chunks |
| `SILENCE_TIMEOUT_MS` | `120000` | Silence before new conversation |

## Design Decisions

See [docs/adr/](docs/adr/) for architectural decision records:

- [0001 — Wi-Fi direct with PSRAM buffer](docs/adr/0001-wifi-direct-with-psram-buffer.md)
- [0002 — ADPCM audio encoding](docs/adr/0002-adpcm-audio-encoding.md)
- [0003 — Store-then-analyze pipeline](docs/adr/0003-store-then-analyze-pipeline.md)
- [0004 — Provider abstraction layer](docs/adr/0004-provider-abstraction-layer.md)
- [0005 — Structured entities + vector search](docs/adr/0005-structured-entities-plus-vector-search.md)

## License

Open source — license TBD.
