# Code Quality Assessment — Echo

## Test

| Area | Dove | Framework | Note |
|---|---|---|---|
| Backend | `backend/tests/` (~113 file `test_*.py`) | pytest 8.3.3, pytest-asyncio (`asyncio_mode = "auto"`), pytest-timeout | Integrazione con Postgres reale (`echo_test`, rifiuta DB senza suffisso `_test`) e Redis finto (`tests/fakes/redis.InMemoryRedis`); provider di azioni finto (`tests/fakes/action_provider.py`); chiavi esterne neutralizzate in `conftest.py`. Sottoinsieme DB-free: `test_adpcm_decoder`, `test_temporal`, `test_chunking`, `test_circuit_breaker` |
| Agente e sicurezza (rilevanti per l'intent) | `test_action_agent.py`, `test_action_policy.py`, `test_action_audit.py`, `test_agent_untrusted.py`, `test_pending_actions.py`, `test_idempotency.py`, `test_key_scopes.py`, `test_mcp_server.py`, `test_mcp_tools.py`, `test_llm_tool_calling.py`, `test_composio_provider.py`, `test_phone_actions.py`, `test_whatsapp.py`, `test_routines_agent.py`, `test_routines_worker.py`, `test_assistant_agent.py`, `test_usage*.py`, `test_rate_limit.py`, `test_circuit_breaker.py`, `test_worker_shutdown.py`, `test_dead_letter_admin.py` | pytest | Copertura per comportamento delle parti che un coordinatore riuserebbe |
| Valutazioni LLM | `backend/evals/` (`llm.py`, `stt.py`, `cases/*.json`) | script propri | Chiamate reali; suite `compat`, `extraction`, `routing`, `answers`, `tools`; non in CI |
| Mobile | `mobile/test/` (97 file) | flutter_test | In CI |
| Firmware | `firmware/test/` (15 suite) | Unity, `native` | In CI |
| Bridge WhatsApp | `whatsapp/test/` (5 file) | `node --test` | In CI |

**Copertura**: nessuna configurazione di coverage e nessuna soglia in CI; la percentuale non è misurata. Il default di scope `classic` (org.md) richiede un floor dell'80% sulle linee: oggi non verificabile.

## Linting e formattazione

- Backend: ruff 0.6.9, `line-length = 100`, regole `E`, `F`, `I`, `N`, `W` (`backend/pyproject.toml`); `ruff format` via pre-commit e `make fmt`; CI esegue `ruff check app/ tests/ evals/`.
- Mobile: `flutter analyze --no-fatal-infos --no-fatal-warnings` con `flutter_lints`.
- Non presenti: type checker (mypy/pyright), regole ruff di sicurezza (`S`) o di bugbear (`B`).

## CI/CD

- `.github/workflows/ci.yml` su push/PR verso `main`: `lint-and-test` (ruff, test DB-free, `alembic upgrade head` su DB vuoto, test completi con timeout 30 s), `firmware-syntax`, `mobile`, `whatsapp-bridge`, `simulator-syntax`.
- Deploy manuale su host singolo: `make deploy` → `scripts/deploy.sh` (build, migrazioni, restart). Nessuna pipeline di CD né ambienti multipli.

## Documentazione

- **Buona**: README completo (API, configurazione, privacy, MCP), glossario `CONTEXT.md`, 10 ADR, 27 spec e 22 piani datati in `docs/superpowers/`, `PROJECT-STATUS.md` e `ROADMAP.md` aggiornati al 28–29/10/2026.
- Docstring di modulo e di funzione molto esplicative e coerenti, con riferimenti incrociati tra moduli.
- Lingua mista: codice e README in inglese, stato e roadmap in italiano.

## Valutazione rapida (scala good/fair/poor)

| Criterio | Voto | Evidenza |
|---|---|---|
| Chiarezza dei nomi | good | Nomi di dominio coerenti (`run_action_agent`, `route_request`, `record_usage`, `owned_by`) |
| Dimensione delle funzioni | fair | Molte funzioni brevi, ma `run_action_agent` (~150 righe), `_answer_query` (~200 righe) e `_run_tool` sono lunghe e con molti parametri |
| Gestione errori | fair | Molto curata nell'agente (esiti sconosciuti, audit dopo rollback, messaggi localizzati) e nei worker (retry, DLQ, requeue); 86 `except Exception`, alcuni silenziosi per scelta (`suppress(Exception)` su marker non critici); percorso sincrono LLM senza timeout/retry propri |
| Presenza di test | good | Test per quasi ogni modulo, inclusi casi di sicurezza dell'agente |
| Duplicazione | fair | Composizione provider + instradamento ripetuti in `routers/query.py`, `workers/voice_requests.py`, `workers/routines.py`; due implementazioni LLM con logica di registrazione costi duplicata |
| Codice morto | good | Pulizia fatta il 14/10 (PROJECT-STATUS); nessun TODO/FIXME reale; 19 `# noqa` motivati |

## Debito tecnico (rilevante per un'architettura multi-agente)

| # | Segnale | Dove | Impatto |
|---|---|---|---|
| TD1 | Circuit breaker unico `openai_breaker` per processo, condiviso tra STT (anche Deepgram) e LLM, usato solo dai worker | `core/circuit_breaker.py`, `workers/retry.py` | Un guasto di un provider blocca tutto; il percorso dell'agente non è protetto |
| TD2 | Nessun timeout/retry esplicito sulle chiamate LLM e sul loop dell'agente nel percorso API (solo `RUN_TIMEOUT_S=60` nelle routine) | `actions/agent.py`, `routers/query.py` | Latenza non limitata; nessun budget per richiesta |
| TD3 | Correlation ID solo HTTP, 8 caratteri, non propagato a code/worker/passi agente/tool | `core/logging.py`, `main.py` | Nessuna traccia end-to-end |
| TD4 | Metriche in memoria per processo, worker senza endpoint, nessuna metrica LLM/tool | `core/metrics.py` | Osservabilità limitata ai conteggi HTTP dell'api |
| TD5 | Stato di processo: rate limit slowapi in memoria, cache Composio, breaker, `_RUNNING` | `core/rate_limit.py`, `actions/composio_provider.py`, `routers/query.py` | Non scala a più repliche |
| TD6 | Isolamento solo applicativo: nessuna FK `user_id` → `users`, nessun RLS | `app/models/` | Un errore di filtro espone dati di altri utenti |
| TD7 | Timezone utente globale | `core/config.user_timezone`, `core/timezone.py` | Errato per utenti in altri fusi (le routine hanno un proprio `timezone`) |
| TD8 | Classificazione tool per parole chiave nello slug | `actions/policy.py` | Euristica; il default `CONFIRM` la rende sicura ma rigida |
| TD9 | Agente non durevole: nessun checkpoint dei passi | `actions/agent.py` | Un riavvio perde il lavoro (ROADMAP "esecuzioni durevoli") |
| TD10 | Tool offerti costruiti come lista statica nel codice | `actions/agent.py` | Nessun registro dinamico di agenti/strumenti |
| TD11 | Prezzi non verificati | `app/usage_prices.py` | Costi stimati |
| TD12 | Nessuna misura di coverage | `pyproject.toml`, CI | Floor dell'80% non verificabile |
| TD13 | Fixture `event_loop` deprecata | `tests/conftest.py` | Aggiornamento a pytest 9 bloccato |
