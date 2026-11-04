# Componenti logici — U1 u1-run-foundation

Dove si applicano i pattern di `security-design.md` e dei requisiti di `construction/u1-run-foundation/nfr-requirements/`. Tutto vive nei processi `api` e `worker` di oggi (ADR-001 in `inception/domain-design/decisions.md`): nessun servizio nuovo. Fonti: `construction/u1-run-foundation/functional-design/functional-spec.md`, `inception/contract-design/contract-summary.md`, `inception/domain-design/components.md`.

## Inventario

| Componente logico | Dove | Processo | Dipende da | Dominio di guasto |
|---|---|---|---|---|
| `core/runs.py` (RunTracker) | nuovo | api, worker | PostgreSQL, `core/redaction.py`, `usage_prices.py` | Postgres giù → nessuna run scritta, richieste invariate (BR1.5) |
| `core/request_budget.py` (RequestLimits) | nuovo | api, worker | nessuno (solo memoria) | nessuno esterno |
| `core/redaction.py` | nuovo (codice spostato da `actions/audit.py` + `redact_for_tracking`) | api, worker | nessuno | nessuno |
| Correlation ID per oggetto (`core/logging.py`) | modificato | api, worker | Redis | Redis giù → correlation ID nuovo nel worker, lavoro invariato |
| Aggancio in `services/usage.record_usage` | modificato | api, worker | `core/runs.py`, `core/request_budget.py` | errore del tracciamento isolato dalla scrittura di `llm_usage` (BR3.6) |
| Chiusura delle interrotte | nuovo task in `workers/main.py` + chiamata all'avvio di `api` | worker, api | `core/runs.py` | Postgres giù → riprova al giro dopo |
| Retention del tracciamento | `workers/retention.py` | worker | `core/runs.py` | errore isolato dalla pulizia audio (D6) |
| `app/cli/runs.py` + `make runs` | nuovo | comando nel container `api` | PostgreSQL | solo l'operatore |
| Migrazione `031_agent_runs` | nuovo | `alembic upgrade` al deploy | PostgreSQL | migrazione additiva, downgrade la elimina |

## Raggio d'azione dei guasti

- **Tracciamento:** il guasto più probabile (database lento o giù) non si propaga mai alla richiesta dell'utente: ogni scrittura usa una sessione propria con errori assorbiti e registrati. Il costo di un guasto è una run mancante o incompleta in `make runs`.
- **Tetto per richiesta:** è solo memoria; un errore di programmazione qui potrebbe fermare una richiesta troppo presto. Mitigazione: senza tetto corrente nessun effetto (BR3.1) e test sui tre limiti.
- **Correlation ID:** Redis giù significa solo un correlation ID diverso tra api e worker per quel Segment; nessun job si perde, perché i messaggi delle code non cambiano (D4).
- **Interruttore:** con `run_tracking_enabled` spento, l'unica differenza rispetto a oggi sono il codice di oscuramento spostato e la scrittura della chiave `corr:segment:{id}`; entrambi coperti dai test esistenti più quelli nuovi.

## Risorse condivise

| Risorsa | Chi la usa in U1 | Isolamento |
|---|---|---|
| Pool di connessioni PostgreSQL (`core/database.py`) | RunTracker, retention, `make runs` | sessioni brevi, una per scrittura; nessuna transazione lunga |
| Redis (`app.state.redis`, client del worker) | chiavi `corr:{tipo}:{id}` | prefisso dedicato, scadenza 48 ore |
| Loop di retention | purge del tracciamento | `try` separato (D6) |

## Collegamenti con le altre unità

- U2 passa `duration_ms` e `attempt` a `record_usage` (C1, BR3.7).
- U3 usa `run_scope`, `record_step` e `charge_step`/`check` nel ciclo dell'agente e nelle routine.
- U4 usa `start_budget`, `run_scope`, `agent_scope`.
- U5 usa `restore_correlation_for("segment", id)` nel worker voce.
