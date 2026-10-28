# Echo — Second Brain AI Wearable

A wearable that listens for speech, transcribes it, extracts structured knowledge and
builds a personal memory you can query in natural language — and, when you ask, acts on your other
apps (email, calendar, chat, tasks, notes).

Current phase: **core beta** — an iPhone, a wearable and a backend run by Echo for its users, with email accounts so
each person has their own memory; the Android app builds from the same code but is not yet tested
([spec](docs/superpowers/specs/2026-10-01-core-beta-design.md), [project status](docs/PROJECT-STATUS.md)).

## What Echo does

- **Remembers.** The wearable records speech (voice activity detection, no wake word), the phone relays
  it over BLE, the backend transcribes it, groups it into conversations, extracts people, your
  promises, ideas, events and notes, and writes a daily digest. Other to-dos are the ones you ask
  Echo for ("Ehi Echo, segnami di comprare il latte"): they go to Echo's list, or to the app you name.
- **Answers.** Ask in the app's chat — typed or dictated — "What did Marco say about the offer?"; Echo
  searches the memory (RAG), first in the conversations of the people the question names, and answers
  in the language of the question. A question that needs live information (the weather, the news,
  today's prices) is looked up on the web, with the sites named; up to 30 searches a day per user.
  Each day and each week get a summary on Today.
- **Today, your way.** What needs you on top, then your sections in your order: what routines
  found, to do today, the appointments still to come, your day's conversations, people, Saved,
  where you've been (with Places visited on) and earlier days. Edit Today hides and moves them;
  search is the icon on top.
- **Answers out loud.** With Spoken answers on (Profile), the phone reads the answer to an
  "Echo, …" request aloud, also with the screen locked: in headphones only, or also on the speaker.
  Echo stops listening while the phone speaks, so it never records its own answer.
- **Other languages, translated.** Add the other languages spoken around you (Profile → Language):
  Echo recognises which one each segment is in, and a conversation's lines in another language
  are tagged and can be translated into yours, under the originals.
- **Reads WhatsApp (optional, unofficial).** Link your number in Profile → WhatsApp and ask "cosa mi
  ha scritto Marco?", or make a routine of it. Private chats only, read-only, held in the bridge's
  memory for 7 days and never written to disk; the connection is not official and WhatsApp may
  block the number (see [the design](docs/superpowers/specs/2026-10-28-whatsapp-design.md)).
- **Acts, only when asked.** "Riassumimi le ultime mail", "Echo, segnami il dentista giovedì alle 15":
  Echo uses your connected apps through [Composio](https://composio.dev), and the iPhone's own
Reminders and Calendar through the app ([ADR 0010](docs/adr/0010-iphone-reminders-and-calendar.md)). Reading and creating run
  right away; sending to other people, modifying and deleting wait for a **Confirm** tap in the app.
  Nothing happens from speech that is not addressed to Echo.
- **Voice requests.** Start a sentence with "Ehi Echo, …" (or "Hey", "Hei", "Ei"; "Echo, …" and
  "Eco, …" alone work too) while wearing the device. After a greeting any spelling counts, so an
  Italian "Echo" transcribed as "ecco" is heard; "ecco" alone is just the word. The answer appears
  in Ask, in your one thread with Echo, with a notification the next time the app wakes up.
- **Does things on its own.** "Ehi Echo, ogni mattina alle 7 dimmi che tempo fa a Milano": a
  routine, run by the server at its time (daily, weekdays, weekly or monthly, at most 10). It
  always reports, only when its condition holds ("dimmi se piove"), or only what is new ("nuove
  posizioni di lavoro"), and stays quiet otherwise. What it found shows on Today ("From your
  routines"), in Ask → Routines by day, in full with its sources, and as a notification; "Ask about
  this" brings a result into the chat. Paused and deleted in Profile → Routines.
- **Comes to you, rarely.** Promises you make ("ti mando il preventivo") are tracked and reminded on
  their day; 10 minutes before a meeting, a briefing on the person if there is something to know.
  When someone whose voice you named starts talking, the phone says at once what you promised
  them, what they promised you and when you last talked (at most once per person every 4 hours).
  At most three notifications a day, none at night, each kind switchable.
- **Knows who is speaking.** Record your voice once in Settings → Voices; name the others by tapping
  them in a transcript. Echo then labels lines with names, and asks "Marco?" when unsure
  ([ADR 0008](docs/adr/0008-voice-fingerprints.md)).
- **Sees, when asked.** "Echo, che pianta è questa?", the camera button in Ask, or a short press of the
  wearable's button (a long press mutes): the wearable's camera
  takes one photo, Echo answers about it in the chat and remembers what it showed. Nothing is kept on
  the wearable ([ADR 0007](docs/adr/0007-camera-photos-on-request.md)).
- **Updates itself.** A firmware version published to the server is offered in Settings → Device
  details and sent to the wearable over Bluetooth; if the new version cannot reach the app, the
  wearable goes back to the previous one ([ADR 0009](docs/adr/0009-firmware-updates-over-ble.md)).

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

### 4. Create your account

```bash
make create-user EMAIL=you@example.com     # asks the password (10+ characters) twice
make set-password EMAIL=you@example.com    # to change it later (it asks whether to sign out every device)
make create-user EMAIL=ada@example.com NEW=1   # another person, with their own memories
make set-plan EMAIL=you@example.com PLAN=unlimited   # free (the default), plus or unlimited
```

A plan sets the speech transcribed a month (free 5 h, plus 25 h, unlimited 150 h), web
searches a day and routines; `PLANS` in `.env` changes the numbers. Past the month's
budget Echo keeps the audio and transcribes the first 10 minutes of each day at once; the
rest waits and is transcribed, oldest first, on the 1st or as soon as the plan is raised.

Others can create their own account from the app (each with separate memories); set
`REGISTRATION_OPEN=false` in `.env` to close that. `create-user` attaches the account to the
existing owner, so data recorded before stays yours. Signing in on a phone gives
that phone its own API key; Settings → Devices lists the phones and revokes one.

For scripts and plain HTTP, `make create-key` still prints a key once. The examples below use `my-secret-key` (`make create-key KEY=my-secret-key`) for local testing
only: that key is public, so never keep it on a backend reachable from the internet
(`make revoke-example-key` deletes it; `make deploy` warns while it is active).

### 5. Flash the wearable and install the app

```bash
cd firmware && pio run -t upload        # XIAO ESP32-S3 Sense
cd ../mobile && flutter run             # see mobile/README.md
```

The app opens on a welcome and signs in with that email and password, or creates an account (the
server address is built into the app, see [mobile/README.md](mobile/README.md)). It then requests
permissions, pairs the wearable, explains what Echo keeps and ends with a first voice request;
pairing can be skipped and done later from Settings. To expose a home server, see
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

With `COMPOSIO_API_KEY` set, open **Settings → Apps** in the app and tap
**Connect** next to Gmail, Google Calendar, Slack, Telegram, Todoist or Notion (or search for other
apps). You log in with the provider in the browser; Composio keeps the account tokens. See
[Actions](#actions-composio). The iPhone's Reminders and Calendar need no Composio: turn them on in
**Settings → On this iPhone**.

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
answer and are not stored in Echo's memory. Every executed call is recorded in **Settings → Activity**
with a short, redacted argument summary.

**Endpoints** (all under `/api/actions`, `X-API-Key` required):
- `GET /toolkits?query=` — toolkits with their connection state.
- `POST /toolkits/{slug}/connect` → `{"url"}` to open in the browser; `DELETE /toolkits/{slug}` — disconnect.
- `GET /pending` — actions still waiting for a Confirm (chat or voice), newest first.
- `POST /pending/{id}/confirm` → `{"status": "executed" | "failed" | "unknown", "message"}`
  (404 not found, 409 already handled, 410 expired); `POST /pending/{id}/cancel`.
- `GET /log?limit=50` — audit log, newest first.
- `GET /voice-updates?since=<ISO>` — new answers in the Voice requests conversation (the app polls
  this when it wakes up and shows a notification).

Without `COMPOSIO_API_KEY` these endpoints answer 503 "Composio is not configured" and the chat keeps
answering from memory only.

## MCP (connected apps)

Claude, Cursor and other assistants can read the user's memory over MCP, read-only:
`https://<server>/mcp` (Streamable HTTP), with a connected app's key from Settings → Devices →
**Connect an assistant** (`POST /api/auth/connected-apps`) in `Authorization: Bearer <key>`.

| Tool | Returns |
|---|---|
| `search_memory(query, date_from?, date_to?, limit?)` | relevant passages and summaries, with the conversations they come from |
| `get_conversation(conversation_id)` | title, time, summary, transcript lines with the speaker, photo descriptions, tasks and events |
| `find_person(name)` | role, what Echo knows, last seen, open tasks, latest conversations |
| `list_tasks(status?, due_before?)` | tasks and promises with the sentence they came from |
| `get_day(date)` | the day's summary and conversations |
| `get_week(week_start)` | the weekly summary, highlights and people |

Nothing can be changed or deleted, no audio or images leave Echo, and text spoken or written by
people comes back in `quoted` fields. A key has 60 calls a minute; each call is logged
(`mcp_calls`) and counted for the user's usage. A phone's key does not work here, and a connected
app's key does not work on the REST API.

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
├── mobile/               # Flutter app for iOS and Android, native projects in ios/ and android/
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
├── scripts/              # deploy.sh (make deploy), firmware-release.sh (make firmware-release)
└── simulator/            # Device simulator (Python)
```

## API Reference

All `/api` endpoints require the `X-API-Key` header, except signing in and creating an account.

### Accounts
- `POST /api/auth/login` (`{email, password, device_name, platform}`) → `{api_key, device_id, user}`:
  a new key for this phone, shown once (the server keeps only its hash). 401 for a wrong email or
  password; 429 after 10 failures in 15 minutes from one address or for one email.
- `POST /api/auth/register` — the same body; creates the account (password of 10+ characters) and
  signs the phone in. 409 if the email has an account, 403 with `REGISTRATION_OPEN=false`, at most
  5 accounts an hour from one address.
- `GET /api/auth/me` → `{email, language, other_languages}`; `PATCH /api/auth/me`
  `{language: "en" | "it"}` — the language the account speaks: the wearable's transcription and
  the app's dictation use it (registration takes the phone's; one Echo does not transcribe yet
  becomes English). `{other_languages: ["en", "es"]}` — up to 4 of en, it, es, fr, de, pt heard
  around the user: transcription then recognises which one each segment is in (Deepgram
  `detect_language` among them; without any, the request is as before).
- `POST /api/auth/connected-apps` (`{name}`) → `{id, name, api_key}`: a **read-only** key for an
  assistant (Claude, Cursor…), shown once, at most 10 per account. It works only on the MCP
  server; the REST API answers it 403 "This key is for connected apps only." Listed by
  `GET /api/auth/devices` with `scope: "read"` (phones and scripts are `"full"`), revoked the same way.
- `POST /api/auth/logout` — revokes the key that sent it. `GET /api/auth/devices` — the phones signed
  in and the other keys; `DELETE /api/auth/devices/{id}` — revoke one.

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

  `POST /api/query/stream` takes the same body and answers as Server-Sent Events: `token`
  (`{"text"}`) for each piece of a memory answer as it is written, then `done` with the full
  response, or `error` (`{"status", "detail"}`).
  Either date bound may be omitted. With `client_request_id`, a retry of the same message returns the
  stored answer (409 "Still working on it" while the first attempt is running), so an action never
  runs twice. The response carries `answer`, `sources`, `session_id` and, when Echo is waiting for a
  confirmation, `pending_action` (`id`, `summary`, `status`, `expires_at`).
  An answer that searched the web also carries `web_sources` (`title`, `url`), kept in the
  history as the message's `citations`.
- `GET /api/chat-sessions/thread` — the thread with Echo (created on first use): voice requests
  and photos land there, typed questions unless a new chat is started, and a routine's result
  only when the user asks about it.
- `GET /api/chat-sessions` (the thread first), `GET /api/chat-sessions/{id}`,
  `DELETE /api/chat-sessions/{id}` — complete chat history.
- `POST /api/query/feedback` — rate an answer (re-ranks future sources).

### Memory
- `GET /api/conversations?limit=&offset=&date_from=&date_to=` — newest first, with `emoji`,
  `duration_s`, `is_open` (still capturing), up to three `people` and `task_count`.
- `GET /api/conversations/{id}` — Segments in order (`segment_id`, `text`, `speaker_label`,
  `status`, `language`, pending ones included) and the extracted entities with their `source_text`.
- `POST /api/conversations/{id}/translate` → `{language, lines: {segment_id: text}}` — the lines
  heard in another language, translated into the account's with the LLM; each is kept, so it is
  translated once (a corrected line is translated again).
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
- `GET /api/digest/weekly?weeks=4`, `POST /api/digest/weekly/{monday}` — weekly summaries (summary,
  highlights, people who came up most), written on Monday at the digest hour for the week before.

### Actions
- See [Actions (Composio)](#actions-composio) for the `/api/actions` endpoints.

### Routines
- Created by asking Echo (chat or voice), never by REST. `GET /api/routines` — newest first, with
  `instruction`, `schedule` and `schedule_text` ("Every day at 07:00"), `mode` (`always`,
  `only_if`, `only_new`), `next_run_at`, `last_status` (`reported`, `nothing`, `failed`,
  `skipped`) and `last_answer`. `PATCH /api/routines/{id}` (`{active}`; resuming counts from
  now), `DELETE /api/routines/{id}`.
- `GET /api/routine-runs?routine_id=&since=&before=&limit=` — the runs, newest first (30 by
  default, at most 100), each with its routine's `instruction`, `mode` and `schedule_text`, its
  `status`, full `text` and `sources`; `next_before` asks for the next page. Kept 90 days.
- `POST /api/routine-runs/{id}/ask` — "Ask about this": adds the run to the thread with Echo
  once, so the next question has it; returns the thread's `session_id` (409 for a run with
  nothing to say).

### Export
- `GET /api/export` — everything about the user as one JSON file (conversations with transcripts and
  photo texts, entities, chats, summaries, voice names); no embeddings, no images.

### Notifications
- `POST /api/notifications/coming-up` (`{phone_events}`) — for Today's agenda: the phone-calendar
  event within the hour and what was said last time with its people or about its title.
- `GET /api/notifications/upcoming?briefings=&promises=&evening=&hours=36` — what the phone should
  schedule (`key`, `kind`, `fire_at`, `title`, `body`, `target`: `person:<id>`, `tasks` or `today`),
  already filtered: only when there is something to do, at most 3 a day, none from 22 to 8.
  What it hands out and the `briefings` switch are kept per day in Redis, so the briefs sent at
  once when a known voice speaks count in the same three.
  `POST` with the same query takes the iPhone calendar's next events, so they get briefings too.

### Voices
- `GET /api/voice-profiles` — the user's voice and the named voices (`fingerprints_enabled` false
  without the model). `POST /api/voice-profiles/self/enroll` (`{started_at, ended_at}`: the user
  read a text aloud then; `waiting` until those segments are transcribed), `DELETE /api/voice-profiles/{id}`.
- `POST /api/segments/{id}/voice` (`{is_self}` or `{person_id}` or `{name}`) — whose voice a segment
  is; the conversation's other segments with that voice are labelled too. `POST /api/segments/{id}/voice/reject`
  — not the suggested person.

### Camera
- `POST /api/photos` (`{"question"?, "chat_session_id"?}`) — the app's camera button: a photo
  request whose answer goes to that chat (or the thread with Echo). Voice requests create their own.
- `POST /api/photos/{id}/ask` (`{"question"}`) — a follow-up about the same photo ("Translate it");
  the question and answer go to the photo's chat.
- `GET /api/device/commands?wait=0..25` — long poll for the phone's and the wearable's commands:
  `take_photo` (relayed to the wearable), `voice_update` (a routine found something or failed:
  check `/api/actions/voice-updates`, which also returns new `routine_runs`, and notify), `person_brief` (`person_id`, `title`, `body`: a known voice started talking, shown at
  once, valid 2 minutes) and `phone_action` (Reminders or Calendar, run by the app,
  which answers with `POST /api/device/commands/{id}/result`). `PUT /api/device/phone-apps`
  (`{reminders, calendar}`) — which of them the app has turned on.
- `PUT /api/photos/{id}/image` — the JPEG (multipart `image`, header `X-Captured-At`); idempotent.
- `POST /api/photos/{id}/failure` (`{"reason": "muted|not_connected|no_camera|capture_failed|busy"}`).
- `GET /api/photos/{id}` (status, answer), `GET /api/photos/{id}/image` (the JPEG).

### Firmware
- Publishing is not an endpoint: `make firmware-release`, run where the server's containers run,
  builds the version in `firmware/src/config.h` and publishes it inside the api container.
- `GET /api/firmware/latest` — the highest version published; `GET /api/firmware/{version}/image`
  — its image, which the app sends to the wearable.

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
| `INCOMPLETE_AUDIO_RETENTION_DAYS` | `7` | Days to keep pending, processing, failed, or unknown-status audio (deferred speech, past the plan's budget, is kept until transcribed) |
| `STT_PROVIDER` / `STT_MODEL` | `openai` / `gpt-4o-transcribe` | STT provider (`openai` or `deepgram`) and model |
| `STT_LANGUAGE` | `it` | Primary language for STT |
| `WHATSAPP_BRIDGE_URL` / `WHATSAPP_BRIDGE_TOKEN` | `http://whatsapp:3100` / a default token (compose) | The WhatsApp bridge (`whatsapp/`) and the token shared with it; set your own token, or an empty URL to turn WhatsApp off |
| `LLM_ANALYSIS_MODEL` | `gpt-6-luna` | Entity extraction, summaries, digest, voice-request check |
| `LLM_QUERY_MODEL` | `gpt-6-luna` | Memory answers and the actions agent |
| `LLM_INTENT_MODEL` | `gpt-6-luna` | Intent check: routes a chat or voice request to memory, an app, or "connect it first" |
| `LLM_ANALYSIS_REASONING_EFFORT` / `LLM_QUERY_REASONING_EFFORT` / `LLM_INTENT_REASONING_EFFORT` | `low` / `low` / `none` | For reasoning models (gpt-5/6); empty for a non-reasoning model, which then gets a temperature. See [docs/MODEL-EVALUATION.md](docs/MODEL-EVALUATION.md) |
| `LLM_ANALYSIS_API` / `LLM_QUERY_API` / `LLM_INTENT_API` | `chat` / `responses` / `chat` | OpenAI API per role: `responses` lets the agent's tools run with reasoning |
| `LLM_VISION_MODEL` / `LLM_VISION_REASONING_EFFORT` / `LLM_VISION_API` | `gpt-6-luna` / `low` / `chat` | Answers about a photo from the wearable camera and describes it for memory |
| `VOICE_MATCH_THRESHOLD` / `VOICE_SUGGEST_THRESHOLD` | `0.6` / `0.45` | Voice similarity from which a segment is that person's / "Marco?" is asked ([ADR 0008](docs/adr/0008-voice-fingerprints.md)) |
| `VOICE_MODEL_PATH` | `/opt/models/voice_embedding.onnx` | Speaker-embedding model (baked into the image); missing = energy rule only |
| `PHOTO_REQUEST_TIMEOUT_S` / `PHOTO_MAX_BYTES` | `90` / `1048576` | A photo the wearable has not sent by then fails (told in the chat); largest JPEG accepted |
| `CHUNK_SIZE_TOKENS` / `CHUNK_OVERLAP_TOKENS` | `500` / `50` | Chunking for embeddings |
| `SILENCE_TIMEOUT_MS` | `120000` | Silence (or time gap) that starts a new conversation |
| `MAX_CONVERSATION_DURATION_MS` | `7200000` | Conversations are split after 2 hours |
| `WEB_SEARCH_PROVIDER` | `openai` | Web search while answering (`none` turns it off); at the plan's daily cap Echo says it cannot look it up |
| `PLANS` | (the defaults) | Per-plan changes as JSON: `monthly_minutes`, `daily_minutes`, `web_searches_per_day`, `routines` (`.env.example`) |
| `USER_TIMEZONE` | `Europe/Rome` | Timezone for relative dates, the digest and calendar requests |
| `DIGEST_LOCAL_HOUR` | `4` | Local hour when the digest of the previous day is written |
| `SPEAKER_THRESHOLD_PERCENTILE` | `0.7` | Energy percentile above which a segment is "self" |
| `SPEAKER_ENERGY_THRESHOLD` | `0` | Fixed energy threshold instead of the percentile (`0` = automatic) |
| `DEEPGRAM_API_KEY` / `DEEPGRAM_MODEL` | — / `nova-3` | With `STT_PROVIDER=deepgram` |
| `CORS_ORIGINS` | `*` | Comma-separated origins allowed to call the API from a browser |
| `CLOUDFLARE_TUNNEL_TOKEN` | — | Starts the tunnel service ([guide](docs/CLOUDFLARE-TUNNEL.md)) |
| `METRICS_TOKEN` | — | Bearer token for Prometheus on `/metrics` (otherwise an API key is required) |
| `REGISTRATION_OPEN` | `true` | Anyone with the app can create an account; `false` closes it (accounts then only with `make create-user`) |

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
- [0007 — Camera photos on request](docs/adr/0007-camera-photos-on-request.md)
- [0008 — Voice fingerprints](docs/adr/0008-voice-fingerprints.md)
- [0009 — Firmware updates over BLE](docs/adr/0009-firmware-updates-over-ble.md)
- [0010 — iPhone Reminders and Calendar](docs/adr/0010-iphone-reminders-and-calendar.md)

Feature designs: [Composio actions](docs/superpowers/specs/2026-10-13-composio-actions-design.md),
[first run and sign-in](docs/superpowers/specs/2026-10-16-first-run-and-sign-in-design.md),
[core beta](docs/superpowers/specs/2026-10-01-core-beta-design.md).

## License

Proprietary: Echo is not open source. All rights reserved.
