# Technology Stack — Echo

## Linguaggi

| Linguaggio | Versione | Dove |
|---|---|---|
| Python | ≥3.11 (`requires-python`, immagine `python:3.11-slim`, ruff `target-version = "py311"`) | `backend/`, `simulator/` |
| JavaScript (ESM) | Node ≥22 | `whatsapp/` |
| Dart | SDK `>=3.2.0 <4.0.0` (Flutter 3.x stable) | `mobile/` |
| Kotlin / Swift | progetti nativi versionati | `mobile/android/`, `mobile/ios/` |
| C++ (Arduino) | `-std=c++11` per i test nativi | `firmware/` |
| SQL | PostgreSQL 16 | migrazioni Alembic, `docs/schema.sql` |
| Bash | — | `scripts/`, `backend/entrypoint.sh` |

## Backend — framework e librerie (versioni bloccate in `backend/pyproject.toml`)

| Libreria | Versione | Uso |
|---|---|---|
| fastapi | 0.162.0 | API HTTP |
| starlette | 1.10.0 | ASGI (necessario per l'SDK MCP) |
| uvicorn[standard] | 0.31.1 | server ASGI |
| sqlalchemy[asyncio] | 2.0.35 | ORM async |
| asyncpg | 0.29.0 | driver PostgreSQL |
| alembic | 1.13.3 | migrazioni |
| pgvector | 0.3.5 | tipi vettoriali |
| redis | 5.1.1 | client async (code, cache) |
| pydantic-settings | 2.5.2 | configurazione |
| openai | 2.54.0 | Chat Completions, Responses, Embeddings, Audio |
| python-multipart | 0.0.32 | upload |
| httpx | 0.27.2 | client HTTP (bridge WhatsApp, test) |
| slowapi | 0.1.9 | rate limit |
| composio | 0.22.0 | azioni su app di terzi (0.24+ evitato: import ~50 s) |
| mcp | 1.30.0 | server MCP (FastMCP, Streamable HTTP) |
| sse-starlette | 3.6.0 | SSE |
| sherpa-onnx | 1.13.8 | impronte vocali (WeSpeaker ResNet34, ONNX su CPU, scaricato nel Dockerfile con verifica SHA-256) |
| argon2-cffi | 23.1.0 | password Argon2id |
| tzdata | 2025.2 | fusi orari |
| pypdf | 6.21.4 | testo PDF |
| python-docx | 1.2.0 | testo Word |

Sviluppo: pytest 8.3.3, pytest-asyncio 0.24.0, pytest-timeout 2.3.1, ruff 0.6.9. Lockfile: `backend/uv.lock`.

## Modelli e servizi AI (configurazione predefinita in `core/config.py`)

| Ruolo | Impostazioni | Default |
|---|---|---|
| Analisi (estrazione, riassunti, digest, verifica richiesta vocale) | `LLM_ANALYSIS_MODEL` / `_REASONING_EFFORT` / `_API` | `gpt-6-luna` / `low` / `chat` |
| Query (risposte RAG, agente) | `LLM_QUERY_MODEL` / `_REASONING_EFFORT` / `_API` | `gpt-6-luna` / `low` / `responses` |
| Intent (instradamento) | `LLM_INTENT_MODEL` / `_REASONING_EFFORT` / `_API` | `gpt-6-luna` / `none` / `chat` |
| Vision (foto) | `LLM_VISION_MODEL` / `_REASONING_EFFORT` / `_API` | `gpt-6-luna` / `low` / `chat` |
| Embedding | `EMBEDDING_MODEL` | `text-embedding-3-small` (1536 dimensioni, fisso nello schema) |
| STT | `STT_PROVIDER` / `STT_MODEL` | `openai` / `gpt-4o-transcribe` (alternativa `deepgram` / `nova-3`) |
| Ricerca web | `WEB_SEARCH_PROVIDER` | `openai` (tool ospitato della Responses API) |
| Provider LLM | `LLM_ANALYSIS_PROVIDER`, `LLM_QUERY_PROVIDER` | solo `openai` implementato |

Prezzi in `backend/app/usage_prices.py` (letti il 2026-10-16, dichiarati non verificati).

## Infrastruttura e runtime

| Elemento | Versione / immagine | Ruolo |
|---|---|---|
| PostgreSQL + pgvector | `pgvector/pgvector:pg16` | dati, vettori |
| Redis | `redis:7-alpine` | code, cache, idempotenza, comandi |
| Docker Compose | — | api, worker, postgres, redis, whatsapp, tunnel |
| Cloudflare Tunnel | `cloudflare/cloudflared:latest` | esposizione pubblica |
| GitHub Actions | `ubuntu-latest`, Python 3.11, Node 22, Flutter stable, PlatformIO | CI |

## Altri pacchetti

- **Bridge WhatsApp**: `baileys` 7.0.0-rc14, `pino` 9.6.0; test con `node --test`.
- **Mobile**: `http` ^1.2.0, `flutter_blue_plus` ^2.3.14, `flutter_secure_storage` ^10.3.1, `shared_preferences` ^2.2.0, `connectivity_plus` 6.1.5, `flutter_local_notifications` 18.0.1, `speech_to_text` ^7.0.0, `flutter_tts` 4.2.5, `flutter_markdown` ^0.7.4+3, `geolocator` 14.1.2, `geocoding` 4.0.0, `image_picker` 1.1.2, `file_picker` 13.3.0, `share_plus` 13.3.0; lint `flutter_lints` ^4.0.0.
- **Firmware**: piattaforma `espressif32`, board `seeed_xiao_esp32s3`, framework Arduino, `h2zero/NimBLE-Arduino@2.3.2`, `kmackay/micro-ecc@1.0.0`; test `unity` su `native`.
- **Qualità**: ruff (lint + format) via pre-commit `v0.6.9`.
