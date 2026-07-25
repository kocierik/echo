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
docker compose exec api python -m alembic stamp head
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

# Stamp Alembic (mark DB as up-to-date)
cd backend
python -m alembic stamp head

docker compose -f docker-compose-infra.yml exec postgres psql -U echo -d echo -c "
INSERT INTO api_keys (user_id, key_hash, name) VALUES (
    'a0000000-0000-0000-0000-000000000001',
    encode(sha256('my-secret-key'::bytea), 'hex'),
    'default'
);"

# Install Python deps
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
pytest tests/test_adpcm_decoder.py tests/test_temporal.py tests/test_chunking.py -v --noconftest

# Integration tests (requires running PostgreSQL)
pytest tests/ -v
```

## Operazioni comuni

### Primo avvio (da zero)

```bash
# 1. Copia e configura environment
cp .env.example .env
# Modifica .env: aggiungi OPENAI_API_KEY

# 2. Avvia tutti i servizi
docker compose up --build -d

# 3. Crea lo schema del database
docker compose exec -T postgres psql -U echo -d echo < docs/schema.sql

# 4. Marca Alembic come aggiornato (il DB ha già lo schema corrente)
docker compose exec api python -m alembic stamp head

# 5. Crea una API key
docker compose exec -T postgres psql -U echo -d echo -c "
INSERT INTO api_keys (user_id, key_hash, name) VALUES (
    'a0000000-0000-0000-0000-000000000001',
    encode(sha256('my-secret-key'::bytea), 'hex'),
    'default'
);"

# 6. Verifica che tutto funzioni
curl http://localhost:8000/health
```

### Dopo un git pull (aggiornamento codice)

```bash
# 1. Ricostruisci le immagini Docker (nuovo codice)
docker compose up --build -d

# 2. Applica eventuali nuove migrazioni al database
docker compose exec api python -m alembic upgrade head

# 3. Riavvia il worker (carica il nuovo codice)
docker compose restart worker

# 4. Verifica
curl http://localhost:8000/health
```

### Reset completo del database (cancella tutti i dati)

```bash
docker compose exec -T postgres psql -U echo -d echo -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
docker compose exec -T postgres psql -U echo -d echo < docs/schema.sql
docker compose exec api python -m alembic stamp head

# Ricrea API key
docker compose exec -T postgres psql -U echo -d echo -c "
INSERT INTO api_keys (user_id, key_hash, name) VALUES (
    'a0000000-0000-0000-0000-000000000001',
    encode(sha256('my-secret-key'::bytea), 'hex'),
    'default'
);"
```

### Troubleshooting

| Errore | Causa | Soluzione |
|--------|-------|-----------|
| `NameError: name 'X' is not defined` nel worker | Colonne nuove nel codice ma non nel DB | `docker compose exec api python -m alembic upgrade head && docker compose restart worker` |
| `relation "query_feedback" does not exist` | Tabella non creata | `docker compose exec api python -m alembic upgrade head` |
| `column "audio_energy" does not exist` | Migrazione non applicata | `docker compose exec api python -m alembic upgrade head` |
| Worker si riavvia in loop | Errore nel codice o DB non aggiornato | `docker compose logs worker --tail 50` per vedere il traceback |
| `alembic.util.exc.CommandError: Can't locate revision` | Alembic non inizializzato | `docker compose exec api python -m alembic stamp 001` poi `upgrade head` |

## Database migrations (Alembic)

We use [Alembic](https://alembic.sqlalchemy.org/) to version database schema changes. This ensures any environment can be brought up-to-date with a single command.

### After pulling new code

```bash
# Docker
docker compose exec api python -m alembic upgrade head

# Local
cd backend && python -m alembic upgrade head
```

### Creating a new migration

When you modify a SQLAlchemy model (add a column, change a type, add an index):

```bash
# Auto-generate from model diff
docker compose exec api python -m alembic revision --autogenerate -m "add xyz column"

# Or with Makefile
make db-new-migration MSG="add xyz column"
```

Review the generated file in `backend/alembic/versions/`, verify the `upgrade()` and `downgrade()` functions, then commit it.

### Rolling back

```bash
# Undo last migration
docker compose exec api python -m alembic downgrade -1

# Check current revision
docker compose exec api python -m alembic current
```

### Fresh database setup

```bash
# Apply SQL schema (creates tables)
docker compose exec -T postgres psql -U echo -d echo < docs/schema.sql

# Tell Alembic the DB is at the current version
docker compose exec api python -m alembic stamp head
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

## STT providers

Echo supports multiple Speech-to-Text providers. Switch via env vars.

### OpenAI (default)

```env
STT_PROVIDER=openai
STT_MODEL=gpt-4o-transcribe
```

Models available:
- `gpt-4o-transcribe` — best accuracy, $0.006/min (recommended)
- `gpt-4o-mini-transcribe` — cheaper, $0.003/min, slightly less accurate
- `whisper-1` — legacy, same price as gpt-4o-transcribe but worse

Supports prompt conditioning (names, jargon) for improved accuracy.

### Deepgram

```env
STT_PROVIDER=deepgram
DEEPGRAM_API_KEY=dg-your-key-here
DEEPGRAM_MODEL=nova-3
```

Get an API key at [console.deepgram.com](https://console.deepgram.com) ($200 free credits).

Pros: very fast, good Italian, built-in punctuation and smart formatting.
Cons: no prompt conditioning (can't bias toward known names).

## Simulator

The simulator runs on your PC and emulates the wearable device using your microphone.

```bash
cd simulator
pip install -r requirements.txt
python simulate_device.py
```

### Key features

- **Pre-buffer (500ms):** captures audio BEFORE the VAD triggers, so you never lose the start of a phrase
- **Utterance segmentation:** segments end on natural pauses (not fixed duration), giving the STT model complete phrases
- **Continuation window (500ms):** if speech resumes within 500ms of a pause, it stays in the same segment
- **Continuous mode (`--continuous`):** records everything in fixed chunks, skips silence-only. Best quality, higher API cost.
- **Local transcription preview:** optional faster-whisper for real-time feedback (install `faster-whisper` to enable)
- **Max segment duration:** 30s safety limit (VAD mode), configurable chunk size (continuous mode)

### Recording modes

**Continuous mode (default):** records everything in fixed 30s chunks. Only skips chunks that are 100% silence. Zero words lost. Best quality.

**VAD mode (`--vad`):** records only when speech is detected. Smart enough to handle natural pauses (2s tolerance + continuation window). Use when cost savings matter more than quality.

### Useful options

```bash
# Default: continuous mode (records everything)
python simulate_device.py

# VAD mode (only records speech, saves API cost)
python simulate_device.py --vad

# Lower VAD threshold if your mic is quiet (VAD mode)
python simulate_device.py --vad --vad-threshold 300

# Amplify microphone signal
python simulate_device.py --gain 5

# Save WAV files for debugging audio quality
python simulate_device.py --save-wav

# Custom chunk duration
python simulate_device.py --segment-duration 20

# List available microphones
python simulate_device.py --list-devices

# Use a specific microphone
python simulate_device.py --device 2
```

## API endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/segments` | Ingest audio from device |
| POST | `/api/query` | RAG query on memory |
| POST | `/api/query/feedback` | Rate a RAG response (👍/👎) |
| GET | `/api/conversations` | List conversations |
| GET | `/api/conversations/{id}` | Conversation detail |
| GET | `/api/entities` | List/filter entities |
| PATCH | `/api/entities/{id}` | Update an entity |
| DELETE | `/api/entities/{id}` | Delete an entity |
| POST | `/api/entities/{id}/merge` | Merge entity into another |
| GET | `/api/entities/stats` | Entity type counts |
| GET | `/api/entities/people` | List people |
| GET | `/api/entities/tasks` | List tasks (filter by done) |
| POST | `/api/entities/deduplicate` | Trigger entity dedup |
| GET | `/api/digest?days=7` | List recent daily digests |
| GET | `/api/chat-sessions` | List saved chat sessions |
| GET | `/api/stats` | System statistics |
| GET | `/health` | Health check (DB + Redis + queues) |
| GET | `/metrics` | Prometheus metrics |

## Environment variables

See `.env.example` for all available configuration options.
