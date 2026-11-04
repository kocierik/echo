# Piano di codice — U1 u1-run-foundation

## Summary

- Builds: tracciamento di esecuzioni e passi, tetto per richiesta, correlation ID tra api e worker, chiusura delle esecuzioni interrotte, `make runs`, misura della copertura
- Touches: `backend/app/core/` (runs, request_budget, redaction, logging, config), `backend/app/models/agent_run.py`, migrazione `031`, `services/usage.py`, `services/llm_openai.py`, `actions/audit.py`, due router e cinque worker per il correlation ID, `app/cli/runs.py`, `Makefile`, `pyproject.toml`
- Tests: 9 file di test nuovi, circa 50 test (unità e integrazione su Postgres e Redis di test), più la suite di oggi verde

Fonti: `construction/u1-run-foundation/functional-design/` (`functional-spec.md`, `rules.md`, `entities.md`), `construction/u1-run-foundation/nfr-requirements/`, `construction/u1-run-foundation/nfr-design/security-design.md` e `logical-components.md`, `inception/contract-design/contract-summary.md` (C1–C4), `inception/units-generation/unit-of-work.md`.

Tutto il codice nuovo è spento di default (`run_tracking_enabled = False`): con l'interruttore spento l'unico effetto visibile è l'oscuramento dell'audit spostato in `core/redaction.py`, che resta identico.

## Decisioni prese qui dai punti delle revisioni accettate

- **Log con `run_id` ed `error_class`** (revisione del design non funzionale): `JSONFormatter` in `core/logging.py` aggiunge `run_id`, `error_class`, `agent_id` all'elenco dei campi extra che stampa.
- **Chiavi `_id`/`_ids` nell'oscuramento**: confronto senza distinzione tra maiuscole e minuscole; il valore passa solo se è una stringa ≤ 64 caratteri senza `@` (un `calendar_id` che è un'email viene ridotto a tipo e lunghezza) o una lista di al più 20 elementi di quel tipo.
- **Chiave del correlation ID**: scritta solo con `run_tracking_enabled` acceso (NFR9.1), prima del `lpush`, con scadenza 7 giorni; un errore Redis viene registrato e il caricamento prosegue. I Segment rimandati oltre 7 giorni (quota mensile) ricevono un correlation ID nuovo quando vengono trascritti: limite accettato e scritto in `code-summary.md`. `queue:reanalysis` non è coperta (non fa parte del percorso di una richiesta).
- **Retention**: la purge del tracciamento ha un `try` separato dalla pulizia dell'audio.
- **`run_scope`**: tratta `asyncio.CancelledError` come chiusura `failed` con `error_class = cancelled` e poi rilancia l'eccezione.
- **Costo con token in cache**: se `usage_prices` ha un prezzo per i token in cache lo usa, altrimenti li conta al prezzo di input.

## Testing Contract

```json
{
  "version": 1,
  "methodology": "test-after",
  "source": "org",
  "ordering": "implement each applicable testable layer, then write and run that layer's tests.",
  "scope": "classic",
  "test_strategy": "standard",
  "project_type": "brownfield",
  "applicable_notes": [
    {
      "layer": "org",
      "text": "We treat tests as a first-class deliverable in every Bolt. The specific\nmethodology (TDD, BDD, ATDD, or classic test-after) is affirmed at\npractices-discovery and recorded in `team.md` under this heading with explicit\n`Methodology` and `Ordering` fields; Code Generation resolves those fields\nindependently from coverage, tooling, and scope notes.\n\nWhen no posture has been affirmed, our default per scope is:\n- **Methodology**: test-after\n- **Ordering**: implement each applicable testable layer, then write and run\n  that layer's tests.\n- `mvp`, `enterprise`, `feature`, `infra`, `classic` add an 80% line-coverage\n  floor and CI execution before merge.\n- `bugfix`, `security-patch` add a targeted regression for the specific\n  bug/vulnerability and require the existing suite to remain green.\n- `express` uses the Minimal strategy: requirement-driven unit tests (one per\n  requirement, with a happy-path floor per component); existing tests remain\n  green.\n- `poc`, `refactor`, `workshop` add no extra new-test floor and require the\n  existing suite to remain green.\n\nThe active `Test Strategy` still applies in every scope and determines test\nvolume/types. Scope floors are additive; they never reduce or replace the\nselected strategy.\n\nBuild and Test verifies defined coverage floors and affirmed quality targets;\nthey may not be weakened to make a step pass.\n\nAffirm a stricter posture in `team.md` if the team commits to one."
    }
  ],
  "obligations": {
    "strategy": "standard",
    "strategy_volume": [
      "Five to eight tests per component.",
      "Unit tests plus integration tests for key boundaries.",
      "Add E2E, performance, or security tests when requirements demand them."
    ],
    "scope_floor": [
      "Keep the existing test suite green.",
      "This scope adds no extra new-test floor beyond the selected test strategy."
    ],
    "combination_rule": "Apply every selected-strategy obligation and every scope-floor obligation; neither replaces the other, and a targeted scope regression may add the narrowest necessary test type beyond the strategy default."
  },
  "plan_profile": {
    "methodology": "test-after",
    "runner_step": "Verify the existing test runner/configuration and record the exact unit-scoped command.",
    "runner_ready_before_first_test": true,
    "testable_layers": [
      "Data model / database behavior",
      "Repository / data access",
      "Business logic",
      "API / endpoint",
      "Frontend behavior"
    ],
    "steps": [
      "Project structure and production configuration skeleton.",
      "Verify the existing test runner/configuration and record the exact unit-scoped command.",
      "Data model / database behavior - implement.",
      "Data model / database behavior - write and run its tests after implementation.",
      "Repository / data access - implement.",
      "Repository / data access - write and run its tests after implementation.",
      "Business logic - implement.",
      "Business logic - write and run its tests after implementation.",
      "API / endpoint - implement.",
      "API / endpoint - write and run its tests after implementation.",
      "Frontend behavior - implement.",
      "Frontend behavior - write and run its tests after implementation.",
      "Environment/build configuration.",
      "Documentation and traceability."
    ]
  },
  "input_sha256": "sha256:b24c961e4be03749ea7b57a644eb905d9a90ad063c32474517d348f17000a7f5",
  "contract_sha256": "sha256:b09f7a61630c8049159f50b50ca885948235f1869c05ad82e90fb8cc2fe88e2e"
}
```

Strati applicabili a U1: modello dati, accesso ai dati (scritture del tracciamento), logica (tetto, oscuramento, correlation ID, aggancio dei costi), comando operatore (al posto di un endpoint). Nessun frontend.

## Passi

- [x] **Step 1 — Configurazione.** In `backend/app/core/config.py` aggiungere `run_tracking_enabled: bool = False`, `run_interrupted_after_seconds: int = 180`, `run_retention_days: int = 30`, `correlation_key_ttl_seconds: int = 604800`. In `core/logging.py` aggiungere `run_id`, `error_class`, `agent_id` ai campi extra di `JSONFormatter`. In `backend/pyproject.toml` aggiungere `pytest-cov` alle dipendenze di sviluppo e aggiornare `uv.lock` con `uv lock`. (BR5.1, NFR10.2, D3)
- [x] **Step 2 — Base dei test.** Ricostruire l'immagine (`make build`) per avere `pytest-cov`, poi eseguire `make test-all` sul codice invariato e annotare in `code-summary.md` totale, passati, falliti e saltati (riferimento prima/dopo). Verificare che il comando di U1 in `unit-test-instructions.md` gira.
- [x] **Step 3 — Modello dati.** `backend/app/models/agent_run.py` con `AgentRun` e `AgentStep` come in `entities.md` (enum come testo, `UNIQUE(run_id, seq)`, `ON DELETE CASCADE`), registrazione in `models/__init__.py`; migrazione `backend/alembic/versions/031_agent_runs.py` (revision `031`, down `030`) che crea le due tabelle con indici su `(user_id, started_at)`, `correlation_id`, `started_at`, e il downgrade che le elimina. (BR5.2, FR11.3, NFR8.2)
- [x] **Step 4 — Test del modello.** `backend/tests/test_agent_run_model.py`: inserimento di una run e due passi, unicità di `(run_id, seq)`, cancellazione a cascata, vincolo `status` non `running` con `ended_at`. In `tests/conftest.py` aggiungere `agent_steps` e `agent_runs` alle tabelle ripulite dopo ogni test. Eseguire il comando di U1.
- [x] **Step 5 — Oscuramento.** `backend/app/core/redaction.py` con `_is_redacted` e `summarize_arguments` spostati da `actions/audit.py` (codice identico) e `redact_for_tracking` (D1 di `security-design.md`, più le regole sulle chiavi `_id` sopra). `actions/audit.py` li importa da `app.core.redaction`. (BR1.7, BR1.9, NFR7.1)
- [x] **Step 6 — Test dell'oscuramento e dei confini.** `backend/tests/test_redaction.py` (chiavi con corpi, `subject`/`query`/`to` ridotti a tipo e lunghezza, `_id` case-insensitive, `calendar_id` email ridotto, numeri piccoli e booleani tenuti, liste lunghe). `backend/tests/test_core_imports.py` (processo pulito, nessun modulo `app.actions`, `app.services`, `app.agents`, `app.workers` caricato importando i tre moduli di core). I test di `test_action_audit.py` restano verdi senza modifiche.
- [x] **Step 7 — Esecuzioni e passi.** `backend/app/core/runs.py`: `RunContext`, ContextVar `current_run`, `open_run`, `record_step`, `close_run`, `run_scope` (anche `CancelledError`), `agent_scope`, `close_interrupted`, `purge_older_than`; sessione propria da `get_session_factory()` per ogni scrittura; errori registrati con `run_id` ed `error_class` e mai rilanciati; costo da `app.usage_prices` con `cost_unknown`. (BR1.1–BR1.8, BR2.1, BR5.3, FR8.1, FR8.6, FR7.6)
- [x] **Step 8 — Tetto della richiesta.** `backend/app/core/request_budget.py`: `RequestLimits`, ContextVar `current_budget`, `start_budget`, `charge_tokens`, `charge_step`, `check` con l'ordine scadenza → token → passi, nessun effetto senza tetto corrente. (BR3.1–BR3.5, FR7.1, FR9.1)
- [x] **Step 9 — Aggancio dei costi.** In `services/usage.record_usage` aggiungere gli argomenti opzionali `duration_ms` e `attempt`; per i `kind` che iniziano con `llm_` chiamare `charge_tokens` e `record_step(kind="llm_call", agent_id=current_agent)` prima della scrittura su `llm_usage`, ciascuno in un proprio `try`. In `services/llm_openai.py` misurare la durata di ogni chiamata e passarla a `record_usage`. (BR3.2, BR3.6, BR3.7)
- [x] **Step 10 — Test della logica.** `backend/tests/test_core_runs.py` (apertura e chiusura, stato finale una volta sola, numerazione dei passi, nessun passo senza run, interruttore spento → nessuna scrittura, errore di database simulato → richiesta non interrotta e log con `run_id`, costo con prezzo ignoto, `run_scope` con eccezione e con cancellazione, due utenti in parallelo isolati, `close_interrupted` con run di 100 e 200 secondi, `purge_older_than` con run di 29 e 31 giorni e passi cancellati, p95 di `record_step` su 200 passi con 10 task concorrenti < 50 ms). `backend/tests/test_request_budget.py` (i tre limiti e il loro ordine, nessun tetto → ok, superamento di una chiamata, task figli che condividono il tetto). `backend/tests/test_usage_tracking_hook.py` (solo `llm_` addebita, embedding e stt no, errore su `llm_usage` non salta l'addebito, passo `llm_call` con agente e durata).
- [x] **Step 11 — Correlation ID.** In `core/logging.py` aggiungere `remember_correlation(redis, kind, object_id)` e `restore_correlation_for(redis, kind, object_id)`. Produttori: `routers/segments.py` (prima del `lpush` su `queue:stt`) e `routers/photos.py` (prima di `queue:photos`). Consumatori: `workers/stt.py`, `workers/analysis.py`, `workers/voice_requests.py` e il worker delle foto ripristinano il correlation ID all'inizio di ogni elemento. Errori Redis registrati, mai fatali. (BR4.1, BR4.2, FR8.2, D4)
- [x] **Step 12 — Test del correlation ID.** `backend/tests/test_correlation.py` con `tests/fakes/redis.py`: caricamento di un Segment con interruttore acceso scrive la chiave prima del `lpush`; spento non scrive nulla; il worker STT ripristina lo stesso ID; chiave assente o scaduta → ID nuovo; Redis che solleva in `remember_correlation` → caricamento riuscito; rilancio dalla dead-letter conserva l'ID.
- [x] **Step 13 — Avvio e retention.** In `workers/main.py` un task `run_interrupted_sweep_loop` (all'avvio e ogni 60 s fino allo shutdown) che chiama `close_interrupted`; nel lifespan di `app/main.py` una chiamata all'avvio; avviso nei log se la soglia è minore del timeout complessivo + 85 s (il timeout complessivo arriva con U4: fino ad allora si usa 45 s). In `workers/retention.py` la chiamata a `purge_older_than(settings.run_retention_days)` in un `try` proprio. (BR2.2, BR2.3, BR5.3, FR7.6)
- [x] **Step 14 — Comando operatore.** `backend/app/cli/runs.py` con `--cid` o `--user` (email o id) e `--last` (default 10); target `runs` nel `Makefile` (`make runs CID=...`, `make runs USER=... [LAST=N]`) come `make usage`; costo indicato come stima e "(costo parziale)" quando serve; codice di uscita ≠ 0 per argomenti mancanti o valori inesistenti. (BR6.1, FR8.3, NFR5.2)
- [x] **Step 15 — Test del comando.** `backend/tests/test_runs_cli.py`: per correlation ID, per utente con due utenti (solo le righe del richiesto), argomenti mancanti, correlation ID inesistente, run con `cost_unknown`.
- [x] **Step 16 — Copertura e build.** Target `coverage-new` nel `Makefile`: esegue la suite con `--cov=app --cov-report=` sul database di test, poi `coverage report --include=<NEW_CODE> --fail-under=80` come comando a sé, con `NEW_CODE` l'elenco dei file nuovi di U1 (`app/core/runs.py`, `app/core/request_budget.py`, `app/core/redaction.py`, `app/models/agent_run.py`, `app/cli/runs.py`). Il comando di verifica `make lint && make test-all` non cambia. (NFR10.1, NFR10.2)
- [x] **Step 17 — Documentazione e tracciabilità.** Docstring di modulo narrative come il resto del codice; `make help` mostra `runs` e `coverage-new`; `code-summary.md`, `source-manifest.json` e `traceability.json` nella cartella di questa fase.

## Tracciabilità dei passi

| Passo | Regole e requisiti |
|---|---|
| 1 | BR5.1, NFR10.2, D3 di security-design |
| 3–4 | BR5.2, FR11.3, NFR8.2 |
| 5–6 | BR1.7, BR1.9, NFR7.1, FR8.4 |
| 7, 10 | BR1.1–BR1.8, BR2.1, BR5.3, FR8.1, FR8.6, FR7.6, NFR5.1, NFR7.3, NFR7.4 |
| 8, 10 | BR3.1–BR3.5, FR7.1, FR9.1 |
| 9, 10 | BR3.2, BR3.6, BR3.7 |
| 11–12 | BR4.1, BR4.2, FR8.2 |
| 13 | BR2.2, BR2.3, BR5.3, NFR8.1 |
| 14–15 | BR6.1, FR8.3, NFR5.2, NFR5.3 |
| 16 | NFR10.1 |
