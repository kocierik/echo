# Coordinatore multi-agente — documenti di progetto

Progetto di un coordinatore centrale che delega le richieste di Echo ad agenti specializzati (Memoria, Azioni, Assistants), con tracciamento, limiti di costo, timeout e confini di sicurezza. Scritto tra il 30 ottobre e il 4 novembre 2026.

## Stato

- Progettazione completa e approvata (requisiti, design, unità, contratti, piano).
- **U1 `u1-run-foundation`** costruita e approvata: tracciamento delle esecuzioni (`agent_runs`, `agent_steps`, `make runs`), tetto per richiesta, correlation ID tra api e worker. Spenta di default (`run_tracking_enabled = False`). Codice nel commit `7b1d416`.
- Da fare, nell'ordine del piano: U3 registro e agente Azioni, U4 chat come coordinatore, U2 resilienza LLM, U5 voce, U6 assistenti come agenti, U7 budget giornaliero; poi una verifica complessiva.

## Documenti

| File | Contenuto |
|---|---|
| `requirements.md` | Requisiti funzionali (FR1–FR11) e non funzionali (NFR1–NFR11) con criteri di accettazione |
| `components.md` | 15 componenti, diagrammi, entità |
| `decisions.md` | 10 decisioni di architettura (ADR-001…ADR-010) |
| `unit-of-work.md`, `unit-of-work-dependency.md`, `unit-of-work-story-map.md` | Le 7 unità, le dipendenze, la mappa requisiti → unità |
| `contract-summary.md` | Contratti tra le parti (C1–C11) |
| `bolt-plan.md`, `risk-and-sequencing-rationale.md` | Ordine di costruzione, definizione di fatto per unità, rischi |
| `u1-run-foundation/` | Design funzionale, requisiti e design non funzionali, piano di codice e riepilogo di U1 |
| `codekb/` | Mappa del codice di Echo al 30 ottobre 2026 |

## Punti aperti

- Il test `tests/test_core_runs.py::test_record_step_p95_stays_under_50_ms` fallisce sotto misura della copertura (`make coverage-new`): saltarlo quando il tracing di coverage è attivo, senza abbassare la soglia.
- Timeout per la chiusura delle esecuzioni interrotte all'avvio; totali di token e costo a zero nelle esecuzioni `interrupted`.
- Prima di costruire U4, misurare con il tracciamento acceso quante richieste reali sono composte, e valutare l'alternativa più semplice: la chat come un solo agente con la memoria come strumento.
