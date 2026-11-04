# Design di sicurezza — U1 u1-run-foundation

Come U1 soddisfa i requisiti di `construction/u1-run-foundation/nfr-requirements/security-requirements.md` e `tech-stack-decisions.md`. Fonti: `construction/u1-run-foundation/functional-design/functional-spec.md`, `inception/contract-design/contract-summary.md` (C1–C4), `inception/domain-design/components.md`, codice esistente in `backend/app/`.

## D1 — Oscuramento più stretto per il tracciamento (NFR7.1, NFR7.2)

La revisione dei requisiti non funzionali ha notato che la regola dell'audit (BR1.7: primi 80 caratteri dei valori non vietati) lascia passare oggetti, ricerche e destinatari (`subject`, `query`, `to`). L'audit li mostra perché serve a capire un'azione confermata; il tracciamento no. Quindi il tracciamento usa una regola propria, più stretta:

- `args_redacted` contiene **solo i nomi delle chiavi e, per ogni valore, il tipo e la lunghezza**, mai il valore: `{"subject": "str(42)", "to": "list(2)", "limit": "int"}`.
- Unica eccezione: le chiavi che finiscono in `_id` o `_ids` e i valori booleani o numerici piccoli (≤ 6 cifre), che non sono contenuto personale e servono a collegare il passo ad altri dati.
- `plan_summary` è costruito dal codice dagli identificatori del registro, mai copiato dal modello (NFR7.2).
- La funzione vive in `core/redaction.py` (`redact_for_tracking`) accanto a `summarize_arguments`, che resta identica per l'audit.

Questa regola sostituisce, per il tracciamento, il troncamento a 80 caratteri di BR1.7; l'audit (`action_log`) non cambia.

```python
def redact_for_tracking(arguments: dict) -> dict:
    out = {}
    for key, value in arguments.items():
        if str(key).endswith(("_id", "_ids")) or isinstance(value, bool):
            out[key] = value
        elif isinstance(value, int) and abs(value) < 1_000_000:
            out[key] = value
        else:
            out[key] = f"{type(value).__name__}({len(value) if hasattr(value, '__len__') else '-'})"
    return out
```

## D2 — Isolamento per utente (NFR5.1, NFR5.2, NFR5.3)

- `open_run` prende `user_id` dall'argomento esplicito; se assente usa `usage_owner.get()`. Nessun altro percorso imposta `user_id`.
- I passi non hanno `user_id` proprio: appartengono alla loro run, quindi non possono avere un utente diverso.
- `make runs USER=...` filtra con `WHERE user_id = :id`; `CID=...` mostra una sola run. Il comando gira solo nel container (`docker compose exec`), come `make usage`: nessun endpoint HTTP nuovo.
- Test: due task concorrenti con utenti diversi aprono run e scrivono passi; ogni run ha solo il proprio `user_id` e i propri passi.

## D3 — Errori senza dati (NFR7.3)

Ogni scrittura del tracciamento è in un `try/except Exception` che registra con `logger.warning("tracking write failed", extra={"run_id", "error_class"})` e il correlation ID già presente nel logger JSON. Nessun argomento, testo o messaggio d'errore del database entra nel log (il messaggio dell'eccezione può contenere valori).

## D4 — Correlation ID senza cambiare le code (NFR9.2)

La revisione del design funzionale e quella dei requisiti non funzionali hanno rilevato che le code trasportano stringhe nude (l'id) e che i produttori sono molti (`routers/segments.py`, `workers/stt.py`, `workers/analysis.py`, `workers/voice_requests.py`, `workers/deferred.py`, `routers/admin.py` per il rilancio dalla dead-letter, `routers/photos.py`, `workers/reanalysis.py` già in JSON). Cambiare il formato richiederebbe un riconoscimento dei due formati, un ordine di rilascio e lascerebbe un rischio al rollback (un worker vecchio che riceve JSON perde il job).

**Decisione:** il formato dei messaggi non cambia. Il correlation ID si salva in Redis accanto all'oggetto a cui appartiene:

- al caricamento di un Segment (`routers/segments.py`) si scrive `corr:segment:{segment_id}` = correlation ID corrente, con scadenza 48 ore;
- al caricamento di una foto (`routers/photos.py`) `corr:photo:{photo_id}`, stessa scadenza;
- ogni worker che preleva un id (`stt`, `analysis`, `voice_requests`, `deferred`, `photos`) chiama `restore_correlation_for("segment" | "photo", id)`: legge la chiave e imposta la ContextVar, o ne crea uno nuovo se la chiave manca o è scaduta;
- il rilancio dalla dead-letter e i re-accodamenti dopo un errore non devono fare nulla: la chiave è legata all'id, non al messaggio.

**Conseguenze:** nessun rischio di rollback (le chiavi vengono ignorate dal codice vecchio), nessuna transizione di formato, una scrittura Redis in più per Segment. La revisione dovrà verificare che la chiave non contiene dati personali: contiene solo un identificatore casuale.

**Alternative scartate:** campo `correlation_id` nel payload JSON con consumatori che accettano entrambi i formati (C3 del contratto: rischio di perdita di job al rollback, 11 punti da cambiare); nessuna propagazione e correlation ID nuovo in ogni worker (non soddisfa FR8.2).

Questo cambia C3 di `contract-summary.md`: il contratto diventa la chiave Redis `corr:{tipo}:{id}`, non un campo del payload. È un cambiamento interno a U1, senza consumatori fuori da U1 e U5.

## D5 — Confini del codice (BR1.9)

- `tests/test_core_imports.py` importa `app.core.runs`, `app.core.request_budget`, `app.core.redaction` in un processo pulito e verifica con `sys.modules` che nessun modulo `app.actions*`, `app.services*`, `app.agents*`, `app.workers*` sia stato caricato.
- `actions/audit.py` importa `summarize_arguments` e `_is_redacted` da `core/redaction.py`; i test dell'audit di oggi restano verdi senza modifiche.

## D6 — Interruttore e dati (NFR9.1, NFR8.1, NFR8.2, NFR11.1)

- `run_tracking_enabled: bool = False` in `core/config.Settings`; spento, `open_run` restituisce un RunContext senza `run_id` e le altre funzioni non scrivono.
- Retention: `purge_older_than(days=30)` chiamata dal loop di `workers/retention.py` in un proprio `try`, separato dalla pulizia dell'audio, così un errore di una non blocca l'altra.
- La migrazione crea `agent_runs` con indice su `(user_id, started_at)` e su `correlation_id`, `agent_steps` con `UNIQUE(run_id, seq)` e `ON DELETE CASCADE` su `run_id`. Nessun segreto o variabile d'ambiente nuova.

## D7 — Copertura del codice nuovo (NFR10.1, NFR10.2)

`pytest-cov` si aggiunge alle dipendenze di sviluppo. `make test-all` resta il comando di verifica e aggiunge `--cov=app`; un passo successivo (`coverage report --include=<file nuovi di U1> --fail-under=80`) misura solo i file nuovi dell'unità, elencati nel Makefile come `NEW_CODE`. Ogni unità successiva aggiunge i propri file a quell'elenco.
