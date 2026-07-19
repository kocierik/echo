# Development Guide

## Prerequisites

- Python 3.11+
- Docker & Docker Compose (for PostgreSQL + Redis)
- PlatformIO (for firmware)
- OpenAI API key

## Quick start (development)

### Option A: Full Docker (recommended)

```bash
cp .env.example .env
# Add your OPENAI_API_KEY to .env

docker compose up --build -d
docker compose exec -T postgres psql -U echo -d echo < docs/schema.sql
docker compose exec postgres psql -U echo -d echo -c "
INSERT INTO api_keys (user_id, key_hash, name) VALUES (
    'a0000000-0000-0000-0000-000000000001',
    encode(sha256('my-secret-key'::bytea), 'hex'),
    'default'
);"
```

Open http://localhost:8000

### Option B: Infrastructure in Docker, backend local

Useful when Docker networking has issues (corporate firewalls, Podman on Windows).

```bash
# Start only DB and Redis
docker compose -f docker-compose-infra.yml up -d

# Apply schema
docker compose -f docker-compose-infra.yml exec -T postgres psql -U echo -d echo < docs/schema.sql
docker compose -f docker-compose-infra.yml exec postgres psql -U echo -d echo -c "
INSERT INTO api_keys (user_id, key_hash, name) VALUES (
    'a0000000-0000-0000-0000-000000000001',
    encode(sha256('my-secret-key'::bytea), 'hex'),
    'default'
);"

# Install Python deps
cd backend
pip install -e ".[dev]"

# Run the API
export DATABASE_URL="postgresql+asyncpg://echo:echo@localhost:5432/echo"
export REDIS_URL="redis://localhost:6379/0"
export AUDIO_STORAGE_PATH="/tmp/echo_audio"
export OPENAI_API_KEY="sk-your-key"
python -m uvicorn app.main:app --reload --port 8000

# In another terminal, run the worker
python -m app.workers.main
```

## Project structure

```
echo/
├── backend/           # Python FastAPI backend
│   ├── app/
│   │   ├── core/      # Config, DB, Auth
│   │   ├── models/    # SQLAlchemy models
│   │   ├── routers/   # API endpoints
│   │   ├── services/  # Business logic (STT, LLM, Embeddings, Dedup)
│   │   └── workers/   # Background processing
│   ├── static/        # Web UI
│   └── tests/         # Unit + integration tests
├── firmware/          # ESP32-S3 Arduino firmware
│   └── src/           # Modules (VAD, ADPCM, HTTP, Buffer, etc.)
└── docs/              # Schema, ADRs, Roadmap
```

## Running tests

```bash
cd backend

# Unit tests (no DB required)
pytest tests/test_adpcm_decoder.py -v --noconftest

# Integration tests (requires running PostgreSQL)
pytest tests/ -v
```

## Firmware development

```bash
cd firmware

# Edit config.h with your Wi-Fi and server settings
# Then:
pio run -t upload    # Flash to device
pio device monitor   # Serial output
```

## Key design decisions

All architectural decisions are documented in `docs/adr/`:

1. **Wi-Fi direct + PSRAM buffer** — no BLE/mobile app in MVP
2. **ADPCM encoding** — 4:1 compression at negligible CPU cost
3. **Store-then-analyze** — never lose audio, analyze async
4. **Provider abstraction** — swap STT/LLM/Embedding providers freely
5. **Entities + vector search** — structured knowledge + semantic retrieval

## Adding a new AI provider

1. Create `app/services/{service}_{provider}.py`
2. Implement the abstract interface (`STTService`, `LLMService`, or `EmbeddingService`)
3. Add a factory function (e.g., `get_stt_service()`)
4. Add config in `app/core/config.py`
5. The worker and routers pick up the new provider via the factory

## API endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/segments` | Ingest audio from device |
| POST | `/api/query` | RAG query on memory |
| GET | `/api/conversations` | List conversations |
| GET | `/api/conversations/{id}` | Conversation detail |
| GET | `/api/entities` | List/filter entities |
| GET | `/api/entities/stats` | Entity type counts |
| GET | `/api/entities/people` | List people |
| GET | `/api/entities/tasks` | List tasks (filter by done) |
| POST | `/api/entities/deduplicate` | Trigger entity dedup |
| GET | `/api/stats` | System statistics |
| GET | `/health` | Health check (DB + Redis) |

## Environment variables

See `.env.example` for all available configuration options.
