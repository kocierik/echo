# Requisiti di sicurezza — U1 u1-run-foundation

U1 è una libreria (tracciamento, tetto per richiesta, correlation ID): non espone endpoint nuovi, non autentica e non chiama servizi esterni. Il suo rischio di sicurezza è nei dati che scrive (`agent_runs`, `agent_steps`) e nei confini di import. Fonti: `construction/u1-run-foundation/functional-design/functional-spec.md` e `rules.md`, `inception/requirements-analysis/requirements.md` (NFR5, NFR7, NFR8, NFR9, NFR10, NFR11), `inception/contract-design/contract-summary.md` (C1–C4).

## Requisiti

| ID | Requisito | Verifica |
|---|---|---|
| NFR5.1 | Ogni riga di `agent_runs` di una richiesta di chat, voce o routine ha lo `user_id` dell'utente che l'ha fatta partire, preso dalla stessa fonte di `usage_owner`; nessuna riga ha uno `user_id` diverso da quello della richiesta | Test con due utenti in parallelo: le run e i passi di A hanno solo lo `user_id` di A |
| NFR5.2 | `make runs` filtra per l'utente indicato dall'operatore e non espone righe di altri utenti nell'elenco per utente | Test del comando con due utenti |
| NFR5.3 | U1 non aggiunge endpoint HTTP: il tracciamento si legge solo con il comando operatore nel container (accesso già limitato all'operatore) | Revisione del diff: nessun router nuovo in U1 |
| NFR7.1 | Nessun corpo di messaggio, testo di risposta, trascrizione o contenuto di documento entra in `agent_runs` o `agent_steps`; gli argomenti degli strumenti sono oscurati con le regole di `actions/audit.py` (BR1.7) | Test: uno strumento con argomenti `body`, `text`, `message_body` produce `args_redacted` con le sole lunghezze; nessuna colonna di testo libero oltre a quelle elencate |
| NFR7.2 | `plan_summary` contiene solo identificatori di agenti dal registro, mai testo dell'utente o del modello | Test: un piano con istruzioni lunghe produce un `plan_summary` di soli identificatori |
| NFR7.3 | Un errore del tracciamento si registra nei log senza dati della richiesta (solo correlation ID, classe dell'errore, run_id) | Test: errore di database simulato, log controllato |
| NFR8.1 | Le righe di tracciamento si cancellano dopo 30 giorni (BR5.3); i passi seguono la loro run per cascade | Test della funzione di retention con righe di 29 e 31 giorni |
| NFR8.2 | Quando Echo avrà la cancellazione di un account, dovrà includere `agent_runs` (le righe hanno `user_id` indicizzato apposta) | Requisito per il futuro, registrato in `contract-summary.md` C4 |
| NFR9.1 | Con `run_tracking_enabled` spento (default), nessuna scrittura avviene e la suite di oggi passa senza modifiche | `make test-all` verde con l'impostazione spenta |
| NFR10.1 | La copertura di riga del codice nuovo di U1 è almeno 80%, misurata in CI | Report di copertura sul codice nuovo |
| NFR11.1 | Nessun nuovo servizio, container o segreto: U1 usa il PostgreSQL e la configurazione di oggi | Revisione del diff di `docker-compose.yml` e `.env.example`: nessuna variabile segreta nuova |

## Confini del codice

- I moduli `app/core/runs.py`, `app/core/request_budget.py` e `app/core/redaction.py` non importano `app.actions`, `app.services`, `app.agents`, `app.workers` (BR1.9). Un test di import fa fallire la CI se succede, così il codice di base non può diventare una strada per raggiungere i provider o il ciclo dell'agente.
- `actions/audit.py` importa l'oscuramento da `core/redaction.py`; il comportamento dell'audit di oggi resta identico (stessi test).

## Minacce considerate

| Minaccia | Mitigazione |
|---|---|
| Dati personali (email, messaggi) finiscono nel tracciamento e restano più a lungo dell'audit | Oscuramento obbligatorio (NFR7.1), nessun campo di testo libero, retention 30 giorni (NFR8.1) |
| Un errore applicativo scrive righe di un utente con lo `user_id` di un altro | `user_id` preso dalla stessa ContextVar dei costi; test con due utenti (NFR5.1) |
| Il tracciamento rallenta o blocca le richieste se il database ha problemi | Errori ignorati e registrati (BR1.5); scritture con sessione propria (BR1.6) |
| Un modulo di base diventa dipendente dai provider e apre un ciclo di import | Test di import (BR1.9) |

Non ci sono obblighi di conformità nuovi: i dati tracciati sono un sottoinsieme oscurato di quelli che `action_log` e `llm_usage` contengono già.
