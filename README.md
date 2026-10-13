# Echo — Second Brain AI Wearable

An open-source wearable device that continuously listens for speech, transcribes it, extracts structured knowledge, and builds a persistent personal memory queryable in natural language.

Current phase: **core beta** — one user, one iPhone, one wearable, one self-hosted backend
([spec](docs/superpowers/specs/2026-10-01-core-beta-design.md), [project status](docs/PROJECT-STATUS.md)).

## Architecture

```
┌──────────────┐  BLE (ADPCM frames,  ┌──────────────┐  HTTP POST   ┌─────────────────────────────┐
│   Wearable   │  ACK windows, CRC)   │  Mobile app  │ ───────────▶ │       FastAPI (api)         │
│  ESP32-S3    │ ───────────────────▶ │  (Flutter)   │              │  /api/segments, /api/query  │
│ VAD + PSRAM  │ ◀── UPLOAD_OK, mute, │  relay + UI  │ ◀─────────── │  conversations, entities…   │
│ ring buffer  │     time sync ────── └──────────────┘              └──────────┬──────────────────┘
└──────────────┘                                                               │ Redis queues
                                                                    ┌──────────▼──────────────────┐
                                                                    │      Background worker      │
                                                                    │ STT → speaker → entities →  │
                                                                    │ chunks/embeddings → rules   │
                                                                    │ + reanalysis, summaries,    │
                                                                    │   digest, retention, DLQ    │
                                                                    └──────────┬──────────────────┘
                                                                    ┌──────────▼──────────────────┐
                                                                    │    PostgreSQL + pgvector    │
                                                                    └─────────────────────────────┘
```

The wearable keeps every Segment in PSRAM until the phone confirms the upload
(`UPLOAD_OK`); see [ADR 0006](docs/adr/0006-ble-relay-through-phone.md).

## Quick Start

### Prerequisites

- Docker & Docker Compose
- OpenAI API key
- For the app: Flutter 3.x (+ Xcode for iOS) — see [mobile/README.md](mobile/README.md)
- For the wearable: PlatformIO and a Seeed Studio XIAO ESP32-S3 Sense

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
- **Worker** (STT, analysis, reanalysis, conversation summaries, daily digest, audio retention)
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

Your API key is `my-secret-key`. Use a long random key outside local testing.

### 5. Flash the wearable and install the app

```bash
cd firmware && pio run -t upload        # XIAO ESP32-S3 Sense
cd ../mobile && flutter run             # see mobile/README.md
```

The app onboarding asks for the server URL and API key, requests permissions and
pairs the wearable. To expose a home server, see [docs/CLOUDFLARE-TUNNEL.md](docs/CLOUDFLARE-TUNNEL.md).

Without hardware, the [simulator](simulator/README.md) or plain HTTP can send audio:

```bash
curl -X POST http://localhost:8000/api/segments \
  -H "X-API-Key: my-secret-key" \
  -H "X-Recorded-At: 2026-07-19T10:30:00Z" \
  -H "X-Duration-Ms: 5000" \
  -F "audio=@segment.adpcm"
```

### 6. Web UI and admin

- http://localhost:8000 — chat with your memory and browse conversations.
- http://localhost:8000/admin.html — stats, health, dead letter queue with retry.

## Project Structure

```
echo/
├── CONTEXT.md            # Domain glossary
├── docker-compose.yml    # Full stack (docker-compose-infra.yml: only Postgres + Redis)
├── docs/
│   ├── PROJECT-STATUS.md # What works, known issues, next steps
│   ├── ROADMAP.md
│   ├── BETA-GATE-CHECKLIST.md
│   ├── adr/              # Architectural Decision Records
│   ├── superpowers/      # Design specs and implementation plans
│   └── schema.sql
├── firmware/             # ESP32-S3 (Arduino + NimBLE), native unit tests in test/
├── mobile/               # Flutter app (iOS-first)
├── backend/
│   ├── app/
│   │   ├── core/         # config, auth, database, logging, circuit breaker, timezone, OAuth state
│   │   ├── models/       # SQLAlchemy models
│   │   ├── routers/      # HTTP API
│   │   ├── services/     # STT/LLM/embeddings, analysis, RAG helpers, calendar, rules
│   │   ├── integrations/ # Integration engine (Todoist, Calendar, Notion, Telegram, Slack)
│   │   └── workers/      # Worker entry, retry, reanalysis, summaries, digest, retention
│   ├── alembic/          # Migrations
│   ├── static/           # Web UI + admin dashboard
│   └── tests/
└── simulator/            # Device simulator (Python)
```

## API Reference

All `/api` endpoints require the `X-API-Key` header.

### Segments
- `POST /api/segments` — ingest an ADPCM Segment (multipart `audio`, max 5 MB). Headers:
  `X-Recorded-At` (ISO 8601), `X-Duration-Ms`, optional `X-Silence-Before-Ms`, `X-Audio-Energy`.
  Idempotent on audio content + `recorded_at`.
- `GET /api/segments/recent?limit=50` — latest Segments, including pending transcriptions.
- `PATCH /api/segments/{id}/transcription` — correct text and speaker (`self`/`other`/`unknown`);
  audited, then the Conversation is reanalysed without triggering integrations or rules.

### Query and chat
- `POST /api/query` — RAG over memory with follow-ups and temporal filtering:

```json
{
  "question": "Cosa mi ha detto Marco ieri?",
  "top_k": 5,
  "session_id": "optional-uuid-for-follow-up",
  "date_from": "2026-07-20T00:00:00Z",
  "date_to": "2026-07-20T23:59:59Z"
}
```

  Either date bound may be omitted. It can also run Google Calendar actions
  ("crea un evento domani alle 15 per un'ora").
- `GET /api/chat-sessions`, `GET /api/chat-sessions/{id}`, `DELETE /api/chat-sessions/{id}` — complete chat history.
- `POST /api/query/feedback` — rate an answer (re-ranks future sources).

### Memory
- `GET /api/conversations`, `GET /api/conversations/{id}`, `DELETE /api/conversations/{id}`
  (deletes audio, Segments, transcriptions, chunks and conversation entities).
- `GET /api/entities`, `/api/entities/stats`, `/api/entities/people`, `/api/entities/tasks`,
  `PATCH|DELETE /api/entities/{id}`, `POST /api/entities/{id}/merge`, `POST /api/entities/deduplicate`.
- `GET /api/digest?days=7`, `GET /api/digest/{date}`, `POST /api/digest/{date}` — daily digests.

### Automations
- `GET|POST /api/rules`, `GET|PATCH|DELETE /api/rules/{id}`, `GET /api/rules/templates/examples`.
- `GET /api/integrations/available`, `GET|POST /api/integrations`, `PATCH|DELETE /api/integrations/{id}`.
- `GET /api/integrations/oauth/google/authorize` → Google consent URL (signed, single-use `state`);
  `GET /api/integrations/oauth/google/callback`.

### Operations
- `GET /api/admin/dead-letter`, `POST /api/admin/dead-letter/retry` — STT, analysis and reanalysis failures.
- `GET /health`, `GET /api/stats`, `GET /metrics` (Prometheus).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgresql+asyncpg://echo:echo@localhost:5432/echo` | PostgreSQL connection |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection |
| `OPENAI_API_KEY` | — | OpenAI API key (required) |
| `AUDIO_STORAGE_PATH` | `/data/audio` | Audio file storage |
| `COMPLETED_AUDIO_RETENTION_HOURS` | `24` | Hours to keep audio after transcription completes |
| `INCOMPLETE_AUDIO_RETENTION_DAYS` | `7` | Days to keep pending, processing, failed, or unknown-status audio |
| `STT_PROVIDER` / `STT_MODEL` | `openai` / `gpt-4o-transcribe` | STT provider (`openai` or `deepgram`) and model |
| `STT_LANGUAGE` | `it` | Primary language for STT |
| `LLM_ANALYSIS_MODEL` | `gpt-4o-mini` | Model for entity extraction and summaries |
| `LLM_QUERY_MODEL` | `gpt-4o` | Model for RAG answers and chat actions |
| `CHUNK_SIZE_TOKENS` / `CHUNK_OVERLAP_TOKENS` | `500` / `50` | Chunking for embeddings |
| `SILENCE_TIMEOUT_MS` | `120000` | Silence (or time gap) that starts a new conversation |
| `MAX_CONVERSATION_DURATION_MS` | `7200000` | Conversations are split after 2 hours |
| `USER_TIMEZONE` | `Europe/Rome` | Timezone for calendar events and relative dates |
| `DEFAULT_EVENT_DURATION_MINUTES` | `60` | Duration of calendar events when none is said |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` / `GOOGLE_REDIRECT_URI` | — | Google Calendar OAuth |
| `OAUTH_STATE_SECRET` | Google client secret | Secret that signs the OAuth `state` |

## Design Decisions

See [docs/adr/](docs/adr/) for architectural decision records:

- [0001 — Wi-Fi direct with PSRAM buffer](docs/adr/0001-wifi-direct-with-psram-buffer.md) (superseded by 0006)
- [0002 — ADPCM audio encoding](docs/adr/0002-adpcm-audio-encoding.md)
- [0003 — Store-then-analyze pipeline](docs/adr/0003-store-then-analyze-pipeline.md)
- [0004 — Provider abstraction layer](docs/adr/0004-provider-abstraction-layer.md)
- [0005 — Structured entities + vector search](docs/adr/0005-structured-entities-plus-vector-search.md)
- [0006 — BLE relay through the phone](docs/adr/0006-ble-relay-through-phone.md)

## License

Open source — license TBD.
