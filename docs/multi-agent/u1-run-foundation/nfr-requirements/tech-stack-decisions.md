# Scelte tecniche — U1 u1-run-foundation

U1 usa lo stack di oggi (`aidlc/spaces/default/codekb/echo/technology-stack.md`) e aggiunge un solo strumento di sviluppo. Fonti: `construction/u1-run-foundation/functional-design/functional-spec.md`, `inception/requirements-analysis/requirements.md` (NFR10, NFR11), `inception/contract-design/contract-summary.md`.

| Ambito | Scelta | Perché |
|---|---|---|
| Linguaggio | Python 3.11 (come oggi) | Stesso package `app`; nessun runtime nuovo (NFR11) |
| Persistenza | PostgreSQL 16 di oggi, SQLAlchemy 2.0 async, due tabelle nuove con migrazione Alembic additiva | Stesso database e stesso stile dei modelli esistenti; migrazione annullabile (FR11.3) |
| Contesto implicito | `contextvars.ContextVar` per RunContext e RequestLimits | Stesso meccanismo di `usage_owner` e `correlation_id` di oggi; i task figli ereditano il contesto |
| Tempo per la scadenza | `time.monotonic()` | La scadenza non deve dipendere da cambi dell'orologio di sistema |
| Scritture del tracciamento | nuova sessione dalla `get_session_factory()` di oggi, commit per operazione | Sopravvive al rollback della richiesta (BR1.6) |
| Payload delle code | **Superato da D4** ([security-design.md](../nfr-design/security-design.md)): il formato dei messaggi non cambia, il correlation ID sta in Redis (`corr:{tipo}:{id}`, 7 giorni). Era: JSON con campo `correlation_id`, scartato per il rischio di perdere job al rollback | È ciò che fa il codice: `remember_correlation` / `restore_correlation_for` in `backend/app/core/logging.py` |
| Comando operatore | `app/cli/runs.py` con `argparse`, target `make runs` nel Makefile, come `make usage` | Stesso schema dei comandi operatore esistenti |
| Misura della copertura (nuovo) | `pytest-cov` come dipendenza di sviluppo, con `--cov=app` e controllo della soglia sul codice nuovo in CI | Oggi la copertura non si misura; serve a NFR10 per tutte le unità |
| Lint e formattazione | ruff 0.6.9 (come oggi) | Regole del progetto in `pyproject.toml` |

## Requisiti tecnici derivati

| ID | Requisito | Verifica |
|---|---|---|
| NFR7.4 | La registrazione di un passo aggiunge al più 50 ms al p95 di una richiesta (una INSERT con sessione propria) | Test di carico leggero: 100 passi registrati, p95 del tempo di `record_step` misurato |
| NFR9.2 | I consumatori delle code accettano sia il payload JSON nuovo sia la stringa di oggi per tutta la durata del rilascio | Test con entrambi i formati su queue:stt, queue:stt:deferred, queue:analysis, queue:voice |
| NFR10.2 | `pytest-cov` aggiunto alle dipendenze di sviluppo; il comando di verifica resta `make lint && make test-all` e la CI riporta la copertura del codice nuovo | Job di CI con il report |
| NFR11.2 | Nessuna nuova dipendenza di runtime | Diff di `pyproject.toml`: solo `pytest-cov` tra le dipendenze di sviluppo |
