# Development Guide

Setup, daily commands and troubleshooting. The [README](../README.md) has the architecture, the
API reference and the configuration table; [PROJECT-STATUS.md](PROJECT-STATUS.md) has what works and
what is left.

## Prerequisites

- Docker & Docker Compose
- An OpenAI API key (optional: Composio for actions, Deepgram for STT)
- Flutter 3.x (+ Xcode for iOS) for the app, PlatformIO for the firmware

## First run

```bash
cp .env.example .env          # set OPENAI_API_KEY (and COMPOSIO_API_KEY for actions)
docker compose up --build -d
make db-migrate               # Alembic creates extensions, tables and indexes
make create-user EMAIL=you@example.com   # your account: the app signs in with it
curl http://localhost:8000/health
```

The published ports (8000, 5432, 6379) listen on `127.0.0.1` only. To reach the API from the phone,
use Cloudflare Tunnel ([CLOUDFLARE-TUNNEL.md](CLOUDFLARE-TUNNEL.md)).

## After a `git pull`

```bash
make deploy                   # build, start, migrate, restart api + worker, health check
```

Or by hand: `docker compose up --build -d`, `make db-migrate`, `docker compose restart api worker`.
Skipping the migrations leaves the code ahead of the database: see [Troubleshooting](#troubleshooting).

## Make targets

| Target | What it does |
|---|---|
| `make up` / `down` / `build` / `logs` / `logs-api` / `logs-worker` | Docker Compose shortcuts |
| `make deploy` | Idempotent build + migrate + restart ([scripts/deploy.sh](../scripts/deploy.sh)) |
| `make db-migrate` | `alembic upgrade head` on the `echo` database |
| `make db-new-migration MSG="..."` | Autogenerate a migration from the models |
| `make db-reset` | Drop and recreate the schema (**deletes all data**) |
| `make create-user EMAIL=…` | Create an account (asks the password); attaches to the owner's existing data; `NEW=1` for another person |
| `make set-password EMAIL=…` | Set an account's password (asks it, and whether to sign out every device) |
| `make create-key` | Create an API key for scripts; random unless `KEY=...` is given, printed only once |
| `make revoke-example-key` | Delete the README's example key `my-secret-key` |
| `make test-all` | All backend tests in the api container, on `echo_test` |
| `make test` | DB-free backend unit tests |
| `make lint` / `make fmt` | ruff check / format, in the api container |
| `make shell` | Shell in the api container |

## Tests

```bash
make test-all                 # backend: api container, echo_test database, fake service keys
cd mobile && flutter analyze && flutter test
cd firmware && pio test -e native
```

- The backend tests delete conversations, segments and entities, so `conftest.py` refuses any
  database whose name does not end in `_test`. `make test-all` creates and migrates `echo_test`
  and uses Redis db 15.
- They never reach real services: `conftest.py` replaces the `.env` keys with the CI values (fake
  OpenAI key, no Composio/Deepgram key) and the HTTP client gets an in-memory Redis. Tests that need
  a provider stub it (`tests/mocks.py`, `tests/fakes/`).
- To run them outside Docker, point `DATABASE_URL` at a `*_test` database and run
  `alembic upgrade head` on it first.
- CI ([.github/workflows/ci.yml](../.github/workflows/ci.yml)) runs ruff, the migrations on an empty
  database, the backend tests, `flutter analyze` + `flutter test`, the firmware build and native tests.

## Evaluating models

`make eval-llm` and `make eval-stt` compare models on Echo's own tasks with real API calls
(cents per run); results and deadlines are in [MODEL-EVALUATION.md](MODEL-EVALUATION.md).

## Database migrations (Alembic)

- An empty database is created by `alembic upgrade head` alone: 001 creates the extensions
  (uuid-ossp, vector) and the baseline tables, 002+ the rest. Every migration skips what already
  exists.
- `docs/schema.sql` is a reference of the schema at the latest migration: never apply it.
- New migration: change the model, `make db-new-migration MSG="add xyz"`, review `upgrade()` and
  `downgrade()` in `backend/alembic/versions/`, commit it.
- Current revision: `docker compose exec api python -m alembic current`.
- Migration 008 drops the `rules` and `integrations` tables (replaced by Composio). Back them up
  first if they hold data you want: `docker compose exec -T postgres pg_dump -U echo -d echo -t rules -t integrations > backup.sql`.

## Mobile app

```bash
cd mobile
cp dart_defines.example.json dart_defines.json   # git-ignored: the server URL
flutter run --dart-define-from-file=dart_defines.json
```

The app signs in to that server (default `https://echo.man.ovh`) with an account made by
`make create-user`; no key is compiled in. Pairing can be skipped and done later from
Settings → Device. Details in [mobile/README.md](../mobile/README.md).

## Firmware

```bash
cd firmware
pio run -t upload            # flash the XIAO ESP32-S3 Sense
pio device monitor           # serial output
```

The wearable talks only BLE to the phone ([ADR 0006](adr/0006-ble-relay-through-phone.md)); tunables
such as `VAD_ENERGY_THRESHOLD` are in `src/config.h`.

Updates without the cable ([ADR 0009](adr/0009-firmware-updates-over-ble.md)): raise
`FIRMWARE_VERSION_*` in `src/config.h`, then from the repository root

```bash
ECHO_API_KEY=... make firmware-release NOTES="what changed"   # ECHO_URL defaults to localhost:8000
```

builds the firmware and publishes it to the server. The app shows "Update Echo" in
Settings → Device; the wearable keeps the new firmware only once the app reconnects to it, and
goes back to the previous one otherwise. The first firmware with updates (0.5.0) is flashed with
the cable.

The camera (OV3660 or OV2640 on the Sense board) is optional: without one the firmware runs as
before and tells the app it has none. Photo size and quality are `PHOTO_FRAME_SIZE` and
`PHOTO_JPEG_QUALITY` in `src/config.h`; the serial monitor logs the sensor found at boot and each
photo's size and capture time ([ADR 0007](adr/0007-camera-photos-on-request.md)).

Button: a push button between D1 (GPIO2) and GND (the internal pull-up is on). A short press
takes a photo (the answer arrives in Voice requests with a notification); holding it for 1.5 s
mutes, or resumes listening, and the app follows. It works muted too.

Battery: the XIAO ESP32-S3 has no battery sense of its own. Solder two 200 kΩ resistors in series
between BAT+ and GND, with the middle point on A0 (GPIO1), then set `BATTERY_DIVIDER_FITTED 1` in
`src/config.h` and flash. The firmware averages a reading every 30 s, converts it with a LiPo
discharge curve and sends the percentage in DEVICE_STATUS; the app shows it on the Today card and
in Settings → Device. Without the divider (the default) the battery is reported as unknown.

## Running the backend outside Docker

With only Postgres and Redis in Docker (`docker-compose-infra.yml`):

```bash
docker compose -f docker-compose-infra.yml up -d
cd backend
pip install -e ".[dev]"      # Python 3.11, as in CI and the image
export DATABASE_URL="postgresql+asyncpg://echo:echo@localhost:5432/echo"
export REDIS_URL="redis://localhost:6379/0"
export AUDIO_STORAGE_PATH="/tmp/echo_audio"
export OPENAI_API_KEY="sk-your-key"
python -m alembic upgrade head
python -m uvicorn app.main:app --reload --port 8000
python -m app.workers.main   # in another terminal
```

## Providers

STT, LLM and embeddings sit behind interfaces in `backend/app/services/` (`STTService`,
`LLMService`, `EmbeddingService`; [ADR 0004](adr/0004-provider-abstraction-layer.md)). To add one,
implement the interface in `app/services/{service}_{provider}.py`, select it in the factory
(`get_stt_service()` and the like) and add its settings to `app/core/config.py`.

STT options:

| `STT_PROVIDER` | Models | Notes |
|---|---|---|
| `openai` (default) | `gpt-4o-transcribe` (until 2027-02-26), `gpt-transcribe` (its replacement), `gpt-4o-mini-transcribe`, `whisper-1` | Prompt conditioning with known names |
| `deepgram` | `DEEPGRAM_MODEL=nova-3`, needs `DEEPGRAM_API_KEY` | Fast; known names sent as keyterms (Nova-3) |

## Simulator

Emulates the wearable with your microphone and posts Segments over HTTP:

```bash
cd simulator
pip install -r requirements.txt
python simulate_device.py -s http://localhost:8000 -k <api-key>
```

By default it records only speech (VAD, `-t` sets the threshold); `--continuous` records everything
in fixed chunks and skips silence. Other options (`--gain`, `--save-wav`, `--list-devices`,
`--device`) are in [simulator/README.md](../simulator/README.md).

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `column ... does not exist`, `relation ... does not exist` | Migrations not applied | `make db-migrate`, then `docker compose restart api worker` |
| Worker restarting in a loop | Code error or database behind | `docker compose logs worker --tail 50` |
| `Can't locate revision` | The database is marked with a revision this code does not know (other branch) | `alembic current`; `alembic stamp head` only if the schema is already at the latest migration |
| `Refusing to run the tests on database 'echo'` | Tests pointed at the dev database | `make test-all` |
| Composio `401 Unauthorized` | `COMPOSIO_API_KEY` is not the project API key | Use the project key (`ak_…`), not the MCP consumer key (`ck_…`); then `docker compose up -d --force-recreate api worker` |
| `.env` change ignored | `docker compose restart` does not reload `env_file` | `docker compose up -d --force-recreate api worker` |
