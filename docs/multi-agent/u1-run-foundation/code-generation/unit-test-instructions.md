# Istruzioni per i test — U1 u1-run-foundation

## Framework e configurazione

- pytest 8.3 con pytest-asyncio e pytest-timeout, come la suite di oggi (`backend/pyproject.toml`, `[tool.pytest.ini_options]`).
- I test girano nel container `api` sul database `echo_test` e sul db Redis 15, mai su `echo`: lo stesso ambiente di `make test-all`.
- `pytest-cov` si aggiunge alle dipendenze di sviluppo (Step 1 del piano); serve solo per la misura della copertura, non per eseguire i test.
- Prerequisiti: `docker compose up -d` (postgres, redis, api) e il database `echo_test` migrato. `make test-all` lo crea e lo migra; per eseguire solo i test di U1 senza tutta la suite, prima una volta:

```bash
docker compose exec -T postgres psql -U echo -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'echo_test'" | grep -q 1 || docker compose exec -T postgres psql -U echo -d postgres -c "CREATE DATABASE echo_test"
docker compose exec -T -e DATABASE_URL=postgresql+asyncpg://echo:echo@postgres:5432/echo_test -e REDIS_URL=redis://redis:6379/15 api python -m alembic upgrade head
```

## Comando dei test di questa unità

```bash
docker compose exec -T -e DATABASE_URL=postgresql+asyncpg://echo:echo@postgres:5432/echo_test -e REDIS_URL=redis://redis:6379/15 api python -m pytest tests/test_agent_run_model.py tests/test_redaction.py tests/test_core_imports.py tests/test_core_runs.py tests/test_request_budget.py tests/test_usage_tracking_hook.py tests/test_correlation.py tests/test_runs_cli.py tests/test_action_audit.py -q -p no:cacheprovider
```

`tests/test_action_audit.py` è incluso perché U1 sposta l'oscuramento dell'audit: deve restare verde senza modifiche.

## Copertura attesa

- La soglia dell'80% di copertura di riga (Testing Contract, piano `classic`) si misura sul codice nuovo dell'unità con `make coverage-new`, un comando a sé che esegue la suite intera con la misura e poi controlla solo i file nuovi. Build and Test la verifica sulla suite completa del progetto assemblato.
- Un'esecuzione limitata ai test di U1 non giudica quella soglia: se `make coverage-new` uscisse con errore solo per la soglia con tutti i test passati, va registrato con i risultati di questa unità, non come test fallito.
- Obiettivo per i file nuovi di U1: almeno 80% di riga, con `core/runs.py` e `core/request_budget.py` sopra il 90% perché sono la base di tutte le altre unità.

```bash
make coverage-new
```

## Mock e stub

- Redis: `tests/fakes/redis.py` (`InMemoryRedis`) per i test del correlation ID; un sottotipo che solleva su `set` per il guasto di Redis.
- Database: il Postgres di test vero per modello, scritture, cascata, purge e chiusura delle interrotte; per il guasto del database un `session_factory` finto che solleva in `commit`.
- Prezzi: `monkeypatch` di `app.usage_prices` per un modello senza prezzo.
- Tempo: le soglie di 100/200 secondi e di 29/31 giorni si ottengono scrivendo `started_at` nel passato, non con attese; la scadenza del tetto con `time.monotonic` sostituito via `monkeypatch`.
- Nessuna chiamata a OpenAI, Composio o altri servizi esterni.

## Dati di test

- Utenti creati con `tests/factories.py`; per l'isolamento due utenti distinti con task concorrenti.
- Ogni test parte con `agent_runs` e `agent_steps` vuote: `tests/conftest.py` le ripulisce dopo ogni test insieme alle altre tabelle.
- Il test di prestazione (p95 di `record_step`) usa 200 passi con 10 task concorrenti ed è marcato con un timeout di 30 secondi come gli altri.
