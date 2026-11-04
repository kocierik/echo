# Code Structure — Echo

## Organizzazione del repository

```
echo/
├── backend/                 # Python 3.11, FastAPI + worker (package "app")
│   ├── app/
│   │   ├── main.py          # app FastAPI, middleware, router, /mcp, /health, /metrics
│   │   ├── core/            # config, auth, database, logging, metrics, rate_limit, circuit_breaker, timezone
│   │   ├── models/          # 30 modelli SQLAlchemy (Base, UUIDPrimaryKey, TimestampMixin)
│   │   ├── schemas/         # pochi schemi Pydantic condivisi (transcription)
│   │   ├── routers/         # 27 router HTTP sotto /api
│   │   ├── services/        # ~55 servizi: provider AI, analisi, memoria, dominio
│   │   ├── actions/         # agente, policy, provider, pending, audit, voce, tool propri ECHO_*
│   │   ├── mcp/             # server MCP (FastMCP) e i sei tool di sola lettura
│   │   ├── workers/         # processo worker: loop asyncio, retry, DLQ, lifecycle
│   │   ├── cli/             # comandi operatore (users, usage, firmware)
│   │   └── usage_prices.py  # prezzi per modello
│   ├── alembic/versions/    # 30 migrazioni (001_baseline … 030_firmware_signature)
│   ├── tests/               # ~113 test pytest + fakes/ (InMemoryRedis, ActionProvider finto)
│   ├── evals/               # valutazioni LLM/STT con chiamate reali (casi JSON)
│   └── pyproject.toml, uv.lock, Dockerfile, entrypoint.sh, alembic.ini
├── whatsapp/                # Node 22: bridge Baileys in sola lettura (src/, test/)
├── mobile/                  # Flutter: lib/{models,screens,services,widgets,utils,theme}, ios/, android/, test/
├── firmware/                # ESP32-S3: src/*.h + main.ino, test/ (Unity native)
├── simulator/               # simulatore del dispositivo (Python)
├── scripts/                 # deploy.sh, firmware-release.sh, firmware-signing-key.sh
├── docs/                    # adr/ (10), superpowers/specs (27) e plans (22), stato, roadmap, schema.sql
├── docker-compose.yml       # api, worker, postgres, redis, whatsapp, tunnel
├── docker-compose-infra.yml # solo postgres + redis
└── Makefile, .github/workflows/ci.yml, .pre-commit-config.yaml, README.md, CONTEXT.md
```

## Classificazione dei file (backend)

| Categoria | File / cartelle |
|---|---|
| Configuration | `app/core/config.py` (`Settings`, pydantic-settings, `.env`), `app/core/database.py` (engine async, `get_db`, `get_session_factory`), `app/usage_prices.py`, `alembic.ini`, `pyproject.toml` |
| Middleware / cross-cutting | `app/main.py` (`correlation_id_middleware`, CORS, gestore `RateLimitExceeded`), `app/core/auth.py` (dipendenze `get_current_api_key`, `get_current_user_id`, `require_operator`, `authenticate_connected_app`), `app/core/rate_limit.py`, `app/core/logging.py`, `app/core/metrics.py`, `app/core/circuit_breaker.py` |
| Controller / Handler | `app/routers/*.py` (27), `app/mcp/server.py` (ASGI `_McpApp`), `app/mcp/tools.py` |
| Service / UseCase | `app/services/*.py` (memoria, analisi, piani, saved, foto, notifiche…), `app/actions/agent.py`, `availability.py`, `pending.py`, `voice.py` |
| Provider adapter | `app/services/llm_base.py` + `llm_openai.py`, `embedding_base.py` + `embedding_openai.py`, `stt_base.py` + `stt_openai.py` / `stt_deepgram.py`, `web_search.py`, `whatsapp_bridge.py`, `app/actions/provider.py` + `composio_provider.py` / `phone_provider.py` / `whatsapp_provider.py` |
| Tool definitions (agente) | `app/actions/routine_tools.py`, `saved_tools.py`, `todo_tools.py`, `fact_tools.py`, `assistant_tools.py` (schemi OpenAI function + `run_*_tool`) |
| Policy / Security | `app/actions/policy.py` (`ToolTier`, `classify_tool`, `classify_call`, `is_people_key`), `app/actions/audit.py` (redazione argomenti, `pending_summary`, `AuditRecorder`) |
| Model / Entity | `app/models/*.py` (30), `app/schemas/transcription.py`, modelli Pydantic definiti dentro i router |
| Background job | `app/workers/*.py` (main + 13 loop + `retry.py`, `dead_letter.py`, `lifecycle.py`) |
| Migration | `alembic/versions/001…030` |
| Utility | `services/chunking.py`, `services/temporal.py`, `services/language.py`, `services/adpcm_decoder.py`, `core/timezone.py` |
| CLI | `app/cli/users.py`, `usage.py`, `firmware.py` |
| Test | `tests/test_*.py`, `tests/conftest.py`, `tests/factories.py`, `tests/mocks.py`, `tests/fakes/` |

## Pattern ricorrenti

- **Provider abstraction (ADR 0004)**: ABC o `Protocol` + implementazione concreta + factory memoizzata con `functools.cache` (`get_llm_query_service`, `get_llm_analysis_service`, `get_llm_intent_service`, `get_llm_vision_service`, `get_embedding_service`, `get_action_provider`). Ogni servizio LLM porta un `kind` usato per i costi.
- **Decoratori di provider**: `WithPhoneApps(composio, phone, toolkits)` e `WithWhatsApp(inner, whatsapp)` compongono più `ActionProvider` in uno; `NO_APPS` è il null object.
- **Tool calling in formato OpenAI function**: tutti gli strumenti (propri `ECHO_*`, Composio, telefono, WhatsApp, `search_memory`) sono dict `{"type": "function", "function": {...}}`; `OpenAIResponsesLLMService` li traduce per la Responses API (`_to_response_tool`).
- **ContextVar per il contesto implicito**: `usage_owner` (costi), `correlation_id` (log), `current_mcp_key` (utente MCP).
- **Sessione DB passata esplicitamente**: le funzioni di servizio ricevono `db: AsyncSession`; "il chiamante fa il commit". `AuditRecorder` avvolge la sessione per salvare l'audit oltre un rollback.
- **Code Redis come liste**: produttori `lpush`, consumatori `brpop`/`rpop` (FIFO); requeue su `CancelledError`; DLQ dopo `RetryExhaustedError`.
- **Claim con SKIP LOCKED**: `workers/routines._claim`, `workers/documents._claim` per evitare doppie esecuzioni.
- **Idempotenza con marker Redis `SET NX`**: `query:req:{user}:{client_request_id}`, `voice:done:{segment_id}`.
- **Testi localizzati in dizionari `TEXTS`/`FAILURE_TEXTS` (en/it)** scelti con `services/language.detect_language`.
- **Prompt costruiti in codice** come costanti stringa (`_SYSTEM_PROMPT`, `INTENT_PROMPT`, `ASSISTANT_CHECK_PROMPT`, `rag_system_prompt`), con sezioni aggiunte condizionalmente.
- **Docstring di modulo narrative**: ogni file spiega il perché e rimanda ai moduli collegati; nomi in inglese idiomatico snake_case.

## Punti di ingresso

| Processo | Entry point |
|---|---|
| API | `uvicorn app.main:app` (`backend/Dockerfile` CMD, singolo processo) |
| Worker | `python -m app.workers.main` (`docker-compose.yml`) |
| CLI | `python -m app.cli.users`, `app.cli.usage`, `app.cli.firmware` (via `Makefile`) |
| Migrazioni | `python -m alembic upgrade head` |
| Eval | `python -m evals.llm`, `python -m evals.stt` |
| Bridge | `node src/main.js` |
| Mobile | `mobile/lib/main.dart` |
| Firmware | `firmware/src/main.ino` |
