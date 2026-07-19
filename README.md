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
                                    └──────────┬──────────────────┘
                                               │
                                    ┌──────────▼──────────────────┐
                                    │   PostgreSQL + pgvector      │
                                    │   (segments, transcriptions, │
                                    │    conversations, chunks,    │
                                    │    entities)                 │
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
- **Worker** (background STT + analysis)
- **PostgreSQL** with pgvector on port 5432
- **Redis** on port 6379

### 3. Initialize the database

On first run, apply the schema:

```bash
docker compose exec postgres psql -U echo -d echo -f /dev/stdin < docs/schema.sql
```

### 4. Create an API key

```bash
docker compose exec postgres psql -U echo -d echo -c "
INSERT INTO api_keys (user_id, key_hash, name) VALUES (
    'a0000000-0000-0000-0000-000000000001',
    encode(sha256('my-secret-key'::bytea), 'hex'),
    'default'
);"
```

Your API key is `my-secret-key`. Use it in the web UI or in the `X-API-Key` header.

### 5. Use the Web UI

Open http://localhost:8000 and enter your API key. Ask questions about your memory.

### 6. Send audio from the device

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
│   └── adr/                     # Architectural Decision Records
├── backend/
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── static/
│   │   └── index.html           # Web UI (chat)
│   └── app/
│       ├── main.py              # FastAPI app
│       ├── core/
│       │   ├── config.py        # Settings (env vars)
│       │   ├── database.py      # Async SQLAlchemy
│       │   └── auth.py          # API key auth
│       ├── models/
│       │   ├── base.py
│       │   ├── segment.py
│       │   ├── transcription.py
│       │   ├── conversation.py
│       │   ├── chunk.py
│       │   ├── entity.py
│       │   └── api_key.py
│       ├── routers/
│       │   ├── segments.py      # POST /api/segments
│       │   └── query.py         # POST /api/query
│       ├── services/
│       │   ├── stt_base.py      # STT interface
│       │   ├── stt_openai.py    # Whisper implementation
│       │   ├── llm_base.py      # LLM interface
│       │   ├── llm_openai.py    # GPT implementation
│       │   ├── embedding_base.py # Embedding interface
│       │   └── embedding_openai.py
│       └── workers/
│           └── main.py          # Background worker
└── firmware/                    # (future) ESP32-S3 Arduino code
```

## API Reference

### POST /api/segments

Receive an audio segment from the device.

**Headers:**
- `X-API-Key`: API key (required)
- `X-Recorded-At`: ISO 8601 timestamp when audio was recorded
- `X-Duration-Ms`: Duration in milliseconds
- `X-Silence-Before-Ms`: Silence before this segment (optional, for conversation grouping)

**Body:** Multipart form with `audio` file (ADPCM)

### POST /api/query

Query personal memory with natural language.

**Headers:**
- `X-API-Key`: API key (required)

**Body:**
```json
{
  "question": "Cosa mi ha detto Marco sulla conferenza?",
  "top_k": 5
}
```

**Response:**
```json
{
  "answer": "Marco ti ha consigliato di...",
  "sources": [
    {
      "conversation_id": "uuid",
      "text": "...",
      "similarity": 0.89
    }
  ]
}
```

## Configuration

All settings are configurable via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgresql+asyncpg://echo:echo@localhost:5432/echo` | PostgreSQL connection |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection |
| `OPENAI_API_KEY` | — | OpenAI API key (required) |
| `AUDIO_STORAGE_PATH` | `/data/audio` | Where to store audio files |
| `AUDIO_RETENTION_DAYS` | `30` | Days to keep raw audio |
| `STT_LANGUAGE` | `it` | Primary language for transcription |
| `LLM_ANALYSIS_MODEL` | `gpt-4o-mini` | Model for entity extraction |
| `LLM_QUERY_MODEL` | `gpt-4o` | Model for RAG answers |
| `CHUNK_SIZE_TOKENS` | `500` | Chunk size for embedding |
| `CHUNK_OVERLAP_TOKENS` | `50` | Overlap between chunks |
| `SILENCE_TIMEOUT_MS` | `120000` | Silence before new conversation (ms) |

## Design Decisions

See [docs/adr/](docs/adr/) for architectural decision records:

- [0001 — Wi-Fi direct with PSRAM buffer](docs/adr/0001-wifi-direct-with-psram-buffer.md)
- [0002 — ADPCM audio encoding](docs/adr/0002-adpcm-audio-encoding.md)
- [0003 — Store-then-analyze pipeline](docs/adr/0003-store-then-analyze-pipeline.md)
- [0004 — Provider abstraction layer](docs/adr/0004-provider-abstraction-layer.md)
- [0005 — Structured entities + vector search](docs/adr/0005-structured-entities-plus-vector-search.md)

## License

Open source — license TBD.
