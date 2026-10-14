# Echo — Second Brain AI Wearable

An open-source wearable that listens for speech, transcribes it, extracts structured knowledge and
builds a personal memory you can query in natural language — and, when you ask, acts on your other
apps (email, calendar, chat, tasks, notes).

Current phase: **core beta** — one user, one iPhone, one wearable, one self-hosted backend
([spec](docs/superpowers/specs/2026-10-01-core-beta-design.md), [project status](docs/PROJECT-STATUS.md)).

## What Echo does

- **Remembers.** The wearable records speech (voice activity detection, no wake word), the phone relays
  it over BLE, the backend transcribes it, groups it into conversations, extracts people, tasks, ideas,
  events and notes, and writes a daily digest.
- **Answers.** Ask in the app's chat — typed or dictated — "What did Marco say about the offer?"; Echo
  searches the memory (RAG) and answers in the language of the question.
- **Acts, only when asked.** "Riassumimi le ultime mail", "Echo, segnami il dentista giovedì alle 15":
  Echo uses your connected apps through [Composio](https://composio.dev). Reading and creating run
  right away; sending to other people, modifying and deleting wait for a **Confirm** tap in the app.
  Nothing happens from speech that is not addressed to Echo.
- **Voice requests.** Start a sentence with "Echo, …" (also "Eco", "Hey/Ehi Echo") while wearing the
  device: the answer appears in the **Voice requests** conversation of the app, with a notification the
  next time the app wakes up.

## Architecture

```
┌──────────────┐  BLE (ADPCM frames,  ┌──────────────┐  HTTPS        ┌──────────────────────────────┐
│   Wearable   │  ACK windows, CRC)   │  Mobile app  │ ────────────▶ │        FastAPI (api)         │
│  ESP32-S3    │ ───────────────────▶ │  (Flutter)   │               │ segments · query · actions   │
│ VAD + PSRAM  │ ◀── UPLOAD_OK, mute, │ relay + UI   │ ◀──────────── │ conversations · entities …   │
│ ring buffer  │     time sync        └──────────────┘               └──────────────┬───────────────┘
└──────────────┘                                                                    │ Redis queues
                                                                     ┌──────────────▼───────────────┐
                                                                     │       Background worker      │
                                                                     │ STT → speaker → entities →   │
                                                                     │ chunks/embeddings · summaries│
                                                                     │ digest · retention · DLQ     │
                                                                     │ "Echo, …" voice requests     │
                                                                     └───────┬──────────────┬───────┘
                                                          ┌──────────────────▼───┐   ┌──────▼───────────┐
                                                          │ PostgreSQL + pgvector │   │ OpenAI · Composio│
                                                          └───────────────────────┘   └──────────────────┘
```

The wearable keeps every Segment in PSRAM until the phone confirms the upload (`UPLOAD_OK`);
see [ADR 0006](docs/adr/0006-ble-relay-through-phone.md). Actions go through a small agent
(`backend/app/actions/`) that calls Composio tools; see [Actions](#actions-composio).

## Quick Start

### Prerequisites

- Docker & Docker Compose
- OpenAI API key
- Optional, for actions on other apps: a [Composio](https://composio.dev) API key
- For the app: Flutter 3.x (+ Xcode for iOS) — see [mobile/README.md](mobile/README.md)
- For the wearable: PlatformIO and a Seeed Studio XIAO ESP32-S3 Sense

### 1. Clone and configure

```bash
git clone <repo-url> echo
cd echo
cp .env.example .env
# Edit .env: set OPENAI_API_KEY (and COMPOSIO_API_KEY to enable actions)
```

### 2. Start all services

```bash
docker compose up --build
```

This starts:
- **API** on http://localhost:8000 (FastAPI; interactive docs at `/docs`)
- **Worker** (STT, analysis, voice requests, reanalysis, conversation summaries, daily digest, audio retention)
- **PostgreSQL** with pgvector on port 5432
- **Redis** on port 6379
- **Tunnel** (Cloudflare, only with `CLOUDFLARE_TUNNEL_TOKEN`)

The ports listen on `127.0.0.1` only; the phone reaches the API through the tunnel.

### 3. Initialize the database

On first run, create the database with the migrations:

```bash
docker compose exec api python -m alembic upgrade head
```

Alembic creates everything (extensions, tables, indexes) on an empty database; `make deploy` runs
it for you. `docs/schema.sql` is only a reference of the schema at the latest migration.

After a `git pull`, run `make deploy` (rebuild, migrate, restart): code ahead of the database
fails with errors such as `column ... does not exist`.

To reset the database (drops all data):

```bash
docker compose exec -T postgres psql -U echo -d echo -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
docker compose exec api python -m alembic upgrade head
```

(`make db-reset` does the same.)

### 4. Create an API key

```bash
make create-key              # prints a random key once
```

The examples below use `my-secret-key` (`make create-key KEY=my-secret-key`) for local testing
only: that key is public, so never keep it on a backend reachable from the internet
(`make revoke-example-key` deletes it; `make deploy` warns while it is active).

### 5. Flash the wearable and install the app

```bash
cd firmware && pio run -t upload        # XIAO ESP32-S3 Sense
cd ../mobile && flutter run             # see mobile/README.md
```

The app onboarding asks for the server URL and API key (both can be compiled in, see
[mobile/README.md](mobile/README.md)), requests permissions and pairs the wearable; pairing can be
skipped and done later from Settings → Device. To expose a home server, see
[docs/CLOUDFLARE-TUNNEL.md](docs/CLOUDFLARE-TUNNEL.md).

Without hardware, the [simulator](simulator/README.md) or plain HTTP can send audio:

```bash
curl -X POST http://localhost:8000/api/segments \
  -H "X-API-Key: my-secret-key" \
  -H "X-Recorded-At: 2026-07-19T10:30:00Z" \
  -H "X-Duration-Ms: 5000" \
  -F "audio=@segment.adpcm"
```

### 6. Connect your apps (optional)

With `COMPOSIO_API_KEY` set, open **Settings → Automations → Integrations** in the app and tap
**Connect** next to Gmail, Google Calendar, Slack, Telegram, Todoist or Notion (or search for other
apps). You log in with the provider in the browser; Composio keeps the account tokens. See
[Actions](#actions-composio).

## Actions (Composio)

**Apps.** Gmail, Google Calendar, Slack, Telegram (as a bot: messages sent to the bot and groups it
is in), Todoist and Notion are offered first; other Composio toolkits can be searched and connected.
Personal WhatsApp and Instagram chats are not supported (no official API).

**How a request runs.** In the chat, memory questions keep the fast RAG path; a request that mentions
an app (mail, calendar, Slack, task, note…) or follows up on an action goes to the actions agent,
which can also search the memory for mixed questions. Voice requests ("Echo, …") are detected after
transcription, assembled across segments until a pause, checked by the model, and answered the same
way into the **Voice requests** conversation.

**Confirmation.** Each tool is classified as *read*, *create* or *confirm*:
- read and create run immediately (e.g. list emails, summarize a channel, create an event or a task);
- sending to other people, modifying and deleting — and creates that invite or notify someone, such
  as an event with attendees — become a **pending action**: the chat shows a card with the full
  recipient list and a preview, and nothing runs until you tap **Confirm**. Pending actions expire
  after 30 minutes and can be confirmed once;
- tools Echo does not know default to *confirm*.

If an app call times out, Echo says it could not verify the outcome instead of claiming it failed —
check the app before trying again.

**Privacy and audit.** Composio receives only the tool arguments (never audio or full transcripts) and
holds the account tokens; email or message contents that Echo reads are sent to OpenAI to write the
answer and are not stored in Echo's memory. Every executed call is recorded in **Settings → Automations
→ Activity** with a short, redacted argument summary.

**Endpoints** (all under `/api/actions`, `X-API-Key` required):
- `GET /toolkits?query=` — toolkits with their connection state.
- `POST /toolkits/{slug}/connect` → `{"url"}` to open in the browser; `DELETE /toolkits/{slug}` — disconnect.
- `POST /pending/{id}/confirm` → `{"status": "executed" | "failed" | "unknown", "message"}`
  (404 not found, 409 already handled, 410 expired); `POST /pending/{id}/cancel`.
- `GET /log?limit=50` — audit log, newest first.
- `GET /voice-updates?since=<ISO>` — new answers in the Voice requests conversation (the app polls
  this when it wakes up and shows a notification).

Without `COMPOSIO_API_KEY` these endpoints answer 503 "Composio is not configured" and the chat keeps
answering from memory only.

## Project Structure

```
echo/
├── CONTEXT.md            # Domain glossary
├── docker-compose.yml    # Full stack (docker-compose-infra.yml: only Postgres + Redis)
├── docs/
│   ├── PROJECT-STATUS.md # What works, known issues, next steps
│   ├── ROADMAP.md
│   ├── DEVELOPMENT.md    # Setup, make targets, tests, troubleshooting
│   ├── CLOUDFLARE-TUNNEL.md
│   ├── BETA-GATE-CHECKLIST.md
│   ├── adr/              # Architectural Decision Records
│   ├── superpowers/      # Design specs and implementation plans
│   └── schema.sql        # Reference only: Alembic creates the database
├── firmware/             # ESP32-S3 (Arduino + NimBLE), native unit tests in test/
├── mobile/               # Flutter app (iOS-first), native projects in ios/ and android/
├── backend/
│   ├── app/
│   │   ├── core/         # config, auth, database, logging, circuit breaker, timezone
│   │   ├── models/       # SQLAlchemy models
│   │   ├── routers/      # HTTP API
│   │   ├── services/     # STT/LLM/embeddings, analysis, memory retrieval, language
│   │   ├── actions/      # Composio provider, tool policy, agent, confirmations, audit, voice
│   │   └── workers/      # Worker entry, voice requests, reanalysis, summaries, digest, retention
│   ├── alembic/          # Migrations
│   └── tests/
├── scripts/deploy.sh     # make deploy
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
  audited, then the Conversation is reanalysed (without running any action).

### Query and chat
- `POST /api/query` — ask the memory, or ask Echo to act on a connected app:

```json
{
  "question": "Cosa mi ha detto Marco ieri?",
  "top_k": 5,
  "session_id": "optional-uuid-for-follow-up",
  "date_from": "2026-07-20T00:00:00Z",
  "date_to": "2026-07-20T23:59:59Z",
  "client_request_id": "optional-uuid-per-message"
}
```

  Either date bound may be omitted. With `client_request_id`, a retry of the same message returns the
  stored answer (409 "Still working on it" while the first attempt is running), so an action never
  runs twice. The response carries `answer`, `sources`, `session_id` and, when Echo is waiting for a
  confirmation, `pending_action` (`id`, `summary`, `status`, `expires_at`).
- `GET /api/chat-sessions` (the Voice requests session first), `GET /api/chat-sessions/{id}`,
  `DELETE /api/chat-sessions/{id}` — complete chat history.
- `POST /api/query/feedback` — rate an answer (re-ranks future sources).

### Memory
- `GET /api/conversations?limit=&offset=&date_from=&date_to=` — newest first, with `emoji`,
  `duration_s`, `is_open` (still capturing), up to three `people` and `task_count`.
- `GET /api/conversations/{id}` — Segments in order (`segment_id`, `text`, `speaker_label`,
  `status`, pending ones included) and the extracted entities with their `source_text`.
- `DELETE /api/conversations/{id}` — deletes audio, Segments, transcriptions, chunks and
  conversation entities.
- `GET /api/search?q=` — conversations (title, summary, transcript) and entities (name, content).
- `GET /api/people` — everyone Echo heard about, most recently seen first, with role, what Echo
  knows about them, conversation count and open tasks naming them; `GET /api/people/{id}` adds
  their conversations, tasks and events.
- `GET /api/entities`, `/api/entities/stats`, `/api/entities/people`,
  `/api/entities/tasks?done=` (with `source_text`),
  `PATCH|DELETE /api/entities/{id}`, `POST /api/entities/{id}/merge`, `POST /api/entities/deduplicate`.
- `GET /api/digest?days=7`, `GET /api/digest/{date}`, `POST /api/digest/{date}` — daily digests.

### Actions
- See [Actions (Composio)](#actions-composio) for the `/api/actions` endpoints.

### Operations
- `GET /api/admin/dead-letter`, `POST /api/admin/dead-letter/retry` — STT, analysis and reanalysis failures.
- `GET /health` (no auth), `GET /api/stats` (the caller's counts),
  `GET /metrics` (Prometheus; `Authorization: Bearer $METRICS_TOKEN` or an API key).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgresql+asyncpg://echo:echo@localhost:5432/echo` | PostgreSQL connection |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection |
| `OPENAI_API_KEY` | — | OpenAI API key (required) |
| `COMPOSIO_API_KEY` | — | Composio API key; enables actions on connected apps |
| `AUDIO_STORAGE_PATH` | `/data/audio` | Audio file storage |
| `COMPLETED_AUDIO_RETENTION_HOURS` | `24` | Hours to keep audio after transcription completes |
| `INCOMPLETE_AUDIO_RETENTION_DAYS` | `7` | Days to keep pending, processing, failed, or unknown-status audio |
| `STT_PROVIDER` / `STT_MODEL` | `openai` / `gpt-4o-transcribe` | STT provider (`openai` or `deepgram`) and model |
| `STT_LANGUAGE` | `it` | Primary language for STT |
| `LLM_ANALYSIS_MODEL` | `gpt-4o-mini` | Entity extraction, summaries, digest, voice-request check |
| `LLM_QUERY_MODEL` | `gpt-4o` | Memory answers and the actions agent |
| `CHUNK_SIZE_TOKENS` / `CHUNK_OVERLAP_TOKENS` | `500` / `50` | Chunking for embeddings |
| `SILENCE_TIMEOUT_MS` | `120000` | Silence (or time gap) that starts a new conversation |
| `MAX_CONVERSATION_DURATION_MS` | `7200000` | Conversations are split after 2 hours |
| `USER_TIMEZONE` | `Europe/Rome` | Timezone for relative dates, the digest and calendar requests |
| `DIGEST_LOCAL_HOUR` | `4` | Local hour when the digest of the previous day is written |
| `SPEAKER_THRESHOLD_PERCENTILE` | `0.7` | Energy percentile above which a segment is "self" |
| `SPEAKER_ENERGY_THRESHOLD` | `0` | Fixed energy threshold instead of the percentile (`0` = automatic) |
| `DEEPGRAM_API_KEY` / `DEEPGRAM_MODEL` | — / `nova-3` | With `STT_PROVIDER=deepgram` |
| `CORS_ORIGINS` | `*` | Comma-separated origins allowed to call the API from a browser |
| `CLOUDFLARE_TUNNEL_TOKEN` | — | Starts the tunnel service ([guide](docs/CLOUDFLARE-TUNNEL.md)) |
| `METRICS_TOKEN` | — | Bearer token for Prometheus on `/metrics` (otherwise an API key is required) |

## Development

- Backend tests: `make test-all` runs them in the api container on the `echo_test` database
  (created and migrated if missing). The tests delete data, so they refuse any database whose
  name does not end in `_test`, and they never use the real keys from `.env`. `make test` runs the
  DB-free subset; `make lint` / `make fmt` run ruff. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
- Mobile: `cd mobile && flutter test`.
- Firmware: `cd firmware && pio test -e native`.
- CI (`.github/workflows/ci.yml`) runs ruff, the backend tests with Postgres/Redis, the Flutter
  analyzer and tests, the firmware build and native tests.

## Design Decisions

See [docs/adr/](docs/adr/) for architectural decision records:

- [0001 — Wi-Fi direct with PSRAM buffer](docs/adr/0001-wifi-direct-with-psram-buffer.md) (superseded by 0006)
- [0002 — ADPCM audio encoding](docs/adr/0002-adpcm-audio-encoding.md)
- [0003 — Store-then-analyze pipeline](docs/adr/0003-store-then-analyze-pipeline.md)
- [0004 — Provider abstraction layer](docs/adr/0004-provider-abstraction-layer.md)
- [0005 — Structured entities + vector search](docs/adr/0005-structured-entities-plus-vector-search.md)
- [0006 — BLE relay through the phone](docs/adr/0006-ble-relay-through-phone.md)

Feature designs: [Composio actions](docs/superpowers/specs/2026-10-13-composio-actions-design.md),
[core beta](docs/superpowers/specs/2026-10-01-core-beta-design.md).

## License

Open source — license TBD.
