# Riepilogo del codice — U1 u1-run-foundation

Tutto il codice nuovo è spento di default (`run_tracking_enabled = False`): con l'interruttore spento non si scrive nulla in `agent_runs`, `agent_steps` né nelle chiavi `corr:*`; l'unico cambiamento visibile è l'oscuramento dell'audit spostato in `core/redaction.py`, identico a prima.

## Base dei test (prima delle modifiche)

`make test-all` sul codice di partenza (con le sole impostazioni inerti dello Step 1), il 2026-10-30:

| Totale | Passati | Falliti | Saltati | Durata |
|---|---|---|---|---|
| 1239 | 1237 | 1 | 1 | 211,9 s |

Il test fallito è già presente prima di U1: `tests/test_users.py::test_create_user_rejects_duplicate_and_short_password` (`create_user` accetta la password "short" invece di rifiutarla). Viene da una modifica temporanea voluta dalla persona in `backend/app/services/passwords.py` (`_check_length` marcato "TEMPORARY", ora nel commit 29823da), fuori da U1: il file non è stato toccato.

## Dopo U1

| Comando | Totale | Passati | Falliti | Saltati | Durata |
|---|---|---|---|---|---|
| `make test-all` | 1328 | 1326 | 1 (lo stesso preesistente) | 1 | 237,2 s |
| `make coverage-new` (suite con `--cov=app`) | 1328 | 1325 | 2 | 1 | 326,5 s |

89 test nuovi, nessuna regressione. In `make coverage-new` il secondo fallimento è `test_record_step_p95_stays_under_50_ms`: vedi sotto.

### Copertura del codice nuovo (`make coverage-new`)

| File | Righe | Mancanti | Copertura |
|---|---|---|---|
| `app/cli/runs.py` | 107 | 4 | 96% |
| `app/core/redaction.py` | 47 | 0 | 100% |
| `app/core/request_budget.py` | 42 | 0 | 100% |
| `app/core/runs.py` | 185 | 2 | 99% |
| `app/models/agent_run.py` | 47 | 0 | 100% |
| **Totale** | 428 | 6 | **99%** |

Soglia dell'80% superata (e oltre il 90% per `core/runs.py` e `core/request_budget.py`); il report è passato, il target esce con errore solo per i due test falliti.

### p95 di `record_step` (NFR7.4, 50 ms)

- Il test scalda prima il pool del motore condiviso (10 connessioni, come un'api in esercizio): aprire una connessione PostgreSQL costa ~0,1 s qui, ~1 s se dieci si aprono insieme, una volta per processo e non per passo.
- Con il pool caldo, 200 passi con 10 task concorrenti: passa in `make test-all` e nelle esecuzioni isolate (misure di prova: p95 ~39 ms, massimo ~46 ms; margine ~10 ms).
- Sotto `--cov=app` lo stesso test misura p95 241,7 ms: il tracciamento riga per riga di coverage rallenta il codice Python (SQLAlchemy ORM), non il database. La soglia di 50 ms non è stata cambiata né il test escluso dalla copertura: lo scarto resta visibile come fallimento di `make coverage-new` e va deciso dalla persona (per esempio misurare la prestazione solo nella suite senza strumentazione).
- Il valore di 225,6 ms osservato dal coordinatore insieme a `test_stt_languages.py` era dovuto alle transazioni appese del difetto qui sotto; dopo la correzione non si ripresenta.

### Blocco della suite completa e correzione

- **Sintomo:** la suite intera si fermava (5 connessioni `idle in transaction` su `SAVEPOINT __asyncpg_savepoint_N__`, pulizia di conftest e `INSERT INTO llm_usage` in attesa per sempre); riprodotto con solo `tests/test_rate_limit.py` + `tests/test_saved_retrieval.py` ("another operation is in progress").
- **Causa:** `startup_close_interrupted()` nel lifespan di `app/main.py` usava il pool condiviso `core.database.engine`. `TestClient(app)` (in `test_rate_limit.py`, `test_actions_router_http.py`) esegue il lifespan su un altro event loop, quindi nel pool restavano connessioni legate a quel loop; i test successivi (MCP, `async_session`) le ricevevano e le operazioni si accavallavano.
- **Correzione:** lo sweep di avvio usa un motore proprio con `NullPool` (una connessione aperta e chiusa subito, poi `dispose`), mai il pool condiviso; `close_interrupted` accetta un `session_factory`. Il ciclo del worker ogni 60 s continua a usare il pool (stesso loop). Regressione: `test_the_api_startup_sweep_leaves_the_shared_pool_usable` in `tests/test_core_runs.py`.
- **Altro difetto di test trovato e corretto:** `test_main_exits_non_zero_with_the_message` chiamava `asyncio.run`, che lascia il thread senza event loop per i test successivi; ora esegue la coroutine in linea.

Il comando dei test di U1 di `unit-test-instructions.md` gira nel container `api` (verificato con `tests/test_action_audit.py`: 18 passati).

## Cosa è stato costruito

| File | Cosa |
|---|---|
| `backend/app/core/config.py` | `run_tracking_enabled` (spento), `run_interrupted_after_seconds` 180, `run_retention_days` 30, `correlation_key_ttl_seconds` 7 giorni |
| `backend/app/core/logging.py` | `run_id`, `error_class`, `agent_id` nei log JSON; `remember_correlation` / `restore_correlation_for` (chiavi Redis `corr:{tipo}:{id}`) |
| `backend/app/models/agent_run.py`, `alembic/versions/031_agent_runs.py` | `AgentRun`, `AgentStep`; migrazione additiva con indici, `UNIQUE(run_id, seq)`, `ON DELETE CASCADE`, vincolo stato/`ended_at` |
| `backend/app/core/redaction.py` | `summarize_arguments`, `_is_redacted` spostati da `actions/audit.py` senza modifiche; `redact_for_tracking` (solo tipo e lunghezza, identificatori `_id`/`_ids` brevi e senza `@`, booleani, interi < 1 000 000) |
| `backend/app/core/runs.py` | `RunContext`, `current_run()`, `open_run`, `record_step`, `close_run`, `run_scope`, `agent_scope`, `close_interrupted`, `purge_older_than`, `step_cost`, `startup_close_interrupted` |
| `backend/app/core/request_budget.py` | `RequestLimits`, `start_budget`, `current_budget()`, `charge_tokens`, `charge_step`, `check` (scadenza → token → passi) |
| `backend/app/services/usage.py`, `services/llm_openai.py` | `record_usage(..., duration_ms, attempt)`: per i `kind` `llm_*` addebito dei token e passo `llm_call`, ciascuno protetto, prima della scrittura su `llm_usage`; il layer LLM misura la durata di ogni chiamata |
| `routers/segments.py`, `routers/photos.py`, `workers/stt.py`, `workers/analysis.py`, `workers/voice_requests.py`, `workers/photos.py` | correlation ID salvato prima del `lpush` e ripristinato da ogni worker per ogni elemento |
| `workers/main.py`, `app/main.py`, `workers/retention.py` | chiusura delle run interrotte all'avvio di api e worker e ogni 60 s; avviso se la soglia è < timeout (45 s) + 85 s; purge a 30 giorni in un `try` proprio |
| `backend/app/cli/runs.py`, `Makefile` | `make runs CID=...` / `make runs USER=... [LAST=N]`; `make coverage-new` |

## Decisioni prese durante la generazione

- **`current_run` e `current_budget` sono funzioni** (come in C1/C2 di `contract-summary.md`); le ContextVar si chiamano `current_run_var` e `current_budget_var`.
- **L'agente corrente è una ContextVar a sé** (`current_agent_var`, impostata da `agent_scope`), esposta come proprietà `RunContext.current_agent`: due agenti in task paralleli della stessa richiesta condividono la run ma ognuno firma i propri passi.
- **`open_run` non legge `usage_owner`**: `usage_owner` vive in `app/services/usage.py` e `core` non può importare `services` (BR1.9). Il chiamante (U3, U4) passa `user_id` esplicito, come prevede la firma di C1.
- **`record_step` ha un argomento in più, `tokens_cached`**, per applicare il prezzo dei token in cache; senza prezzo in cache si usa quello di input.
- **`close_run` e `open_run` sollevano `ValueError` solo per errori di programmazione** (stato non finale, origine sconosciuta); `record_step` non solleva mai, nemmeno per un tipo di passo sconosciuto (lo registra nei log).
- **Lettura della chiave del correlation ID solo con l'interruttore acceso**: spento, ogni worker genera un correlation ID nuovo per ogni elemento senza chiamare Redis.
- **Sweep all'avvio con connessione propria** (`startup_close_interrupted`, `NullPool`): vedi "Blocco della suite completa".
- **Test di migrazione esistente aggiornato:** `tests/test_migrations.py` contava le revisioni fino a 030; ora fino a 031.
- **`pytest-cov` nel container in esecuzione:** l'immagine è stata ricostruita (`make build`) ma il container `api` non è stato ricreato per non riavviare il servizio; la stessa versione fissata (`pytest-cov==5.0.0`) è stata installata nel container in esecuzione. Al prossimo `docker compose up` l'immagine nuova la contiene già.
- **Retention:** `purge_older_than` lascia risalire gli errori al loop, che li registra in un `try` separato dalla pulizia dell'audio; `close_interrupted` invece non solleva mai (gira all'avvio di api).
- **`make runs`:** `USER` è anche il nome dell'utente della shell, quindi il target usa `--user` solo se `USER=` è dato sulla riga di comando di make. I testi del comando sono in inglese come gli altri comandi operatore: "(partial cost: a model has no price)" corrisponde a "(costo parziale)" del piano.
- **Copertura:** i dati di coverage stanno in `/tmp` del container (`COVERAGE_FILE`), mai nell'albero di lavoro; il report gira anche se un test fallisce e il target esce con errore se uno dei due fallisce.

## Limiti accettati

- I Segment rimandati oltre 7 giorni (quota mensile) trovano la chiave scaduta e ricevono un correlation ID nuovo quando vengono trascritti.
- `queue:reanalysis` non è coperta (non fa parte del percorso di una richiesta).
- BR1.1 (aprire una run solo per lavoro nuovo) e il timeout complessivo della richiesta arrivano con i chiamanti (U3, U4); fino ad allora l'avviso sulla soglia usa 45 s.
