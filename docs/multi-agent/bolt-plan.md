# Piano dei Bolt — Coordinatore multi-agente per Echo

Un **Bolt** è un giro di costruzione su un pezzo del lavoro che finisce con qualcosa che gira e si può provare. Qui ogni Bolt contiene una sola unità di lavoro (risposta Q3). I Bolt si costruiscono uno dopo l'altro (Q4), ciascuno dietro la propria impostazione spenta di default (FR11.1), e ogni Bolt chiude con la verifica del progetto e la tua approvazione. Il piano `classic` non usa un "walking skeleton" (una prima fetta minima da un capo all'altro con un'approvazione separata): nessun Bolt porta quel segno.

Fonti: `inception/units-generation/unit-of-work.md`, `unit-of-work-dependency.md`, `unit-of-work-story-map.md`, `inception/contract-design/contract-summary.md`, `inception/domain-design/components.md`, `inception/requirements-analysis/requirements.md`, risposte in `delivery-planning-questions.md`.

## Sequenza

| # | Bolt | Unità | Dipende da (DAG) |
|---|---|---|---|
| 1 | Base di tracciamento e budget | U1 u1-run-foundation | — |
| 2 | Registro e agente Azioni | U3 u3-registry-and-actions-agent | U1 |
| 3 | La chat come coordinatore | U4 u4-coordinator-ask | U1, U3 |
| 4 | Resilienza LLM | U2 u2-llm-resilience | U1 |
| 5 | Voce dal coordinatore | U5 u5-voice-coordinator | U4 |
| 6 | Assistenti come agenti | U6 u6-assistant-agents | U3 |
| 7 | Budget giornaliero | U7 u7-daily-budget | U4 |

## Bolt 1 — Base di tracciamento e budget (U1)

- **Contiene:** `core/runs.py`, `core/request_budget.py`, `core/redaction.py` (oscuramento spostato da `actions/audit.py`), tabelle `agent_runs` e `agent_steps`, addebito dei token e passo `llm_call` in `services/usage.record_usage` (solo per i `kind` di completamento del modello), correlation ID nelle code, chiusura delle esecuzioni interrotte (task del worker ogni 60 s e all'avvio), retention 30 giorni, `make runs`, impostazioni.
- **Definition of Done:**
  - Migrazione additiva applicata e annullabile; la suite esistente resta verde.
  - Test di import: nessun modulo di `core` importa `actions`, `services`, `agents` o `workers`.
  - Un'esecuzione e i suoi passi si scrivono e si leggono con `make runs`; un errore di scrittura non fa fallire la richiesta (FR8.6).
  - Un'esecuzione lasciata `running` diventa `interrupted` entro timeout + 60 s (FR7.6).
  - Copertura del codice nuovo almeno 80%.
- **Ipotesi da verificare:** il tracciamento in Postgres si aggiunge senza toccare il comportamento di oggi e senza rallentare le richieste di più di 50 ms al p95 (NFR7).
- **Demo:** con l'impostazione accesa in locale, una richiesta di chat produce un'esecuzione visibile in `make runs` con lo stesso correlation ID dei log.

## Bolt 2 — Registro e agente Azioni (U3)

- **Contiene:** `agents/types.py`, `agents/registry.py` validato all'avvio, `agents/actions_agent.py`, i quattro parametri opzionali di `run_action_agent` (strumenti permessi, untrusted iniziale, rispetto del budget, registrazione dei passi), routine tracciate.
- **Definition of Done:**
  - Prima di toccare `actions/agent.py`: test che fissano il comportamento di oggi del percorso delle conferme (pending action, `_LASTING_OWN`, esiti `unknown`), eseguiti prima e dopo (rischio principale, Q6).
  - Senza i nuovi parametri, `run_action_agent` si comporta esattamente come oggi (stessi test verdi).
  - Una chiamata fuori elenco è rifiutata e registrata senza contattare il provider (FR6.1).
  - Ogni strumento di invio/modifica/cancellazione passa da `pending_action` da qualunque agente (NFR4).
  - Le routine aprono un'esecuzione con origine `routine` (FR8.5).
  - Copertura del codice nuovo almeno 80%.
- **Ipotesi da verificare:** l'agente di oggi si può avvolgere con permessi più stretti senza cambiare una riga della policy delle conferme.
- **Demo:** una routine eseguita in locale compare in `make runs` con i suoi passi di strumento e gli argomenti oscurati.

## Bolt 3 — La chat come coordinatore (U4)

- **Contiene:** `agents/coordinator.py`, `agents/memory_agent.py`, DelegationPlan in `actions/availability.py`, interruttore in `routers/query.py` (JSON e SSE), sintesi, propagazione del non fidato, risposte parziali.
- **Definition of Done:**
  - Con l'impostazione spenta, la suite esistente è verde senza modifiche (FR11.1, NFR9); i test MCP passano senza modifiche (FR10.1).
  - Con l'impostazione accesa: percorso veloce con lo stesso numero di chiamate LLM di prima (FR1.3, NFR3); "cosa mi ha promesso Marco? aggiungilo a Todoist" delega a Memoria e poi ad Azioni e crea il task (FR1.4); test con due utenti per l'isolamento (NFR5); eventi SSE identici a oggi (C11).
  - Misura del p95 del primo token sulle domande del percorso veloce prima e dopo, entro +300 ms (NFR1).
  - Copertura del codice nuovo almeno 80%.
- **Ipotesi da verificare:** un piano in una chiamata basta a gestire le richieste composte in italiano senza peggiorare le domande semplici.
- **Demo:** in Ask, una domanda semplice e una composta; per la seconda, `make runs` mostra piano, due deleghe, sintesi e costo.

## Bolt 4 — Resilienza LLM (U2)

- **Contiene:** breaker per provider in `core/circuit_breaker.py`, timeout e retry con jitter per le chiamate al modello in `services/llm_openai.py`, `ProviderUnavailable`.
- **Definition of Done:**
  - Un guasto simulato di Deepgram non apre il breaker del LLM (FR7.4).
  - Con il breaker LLM aperto la chat risponde entro 1 s con un messaggio localizzato e nessuna chiamata a OpenAI.
  - 429 due volte e poi 200: la richiesta riesce e il tracciamento mostra 3 tentativi (FR7.2); i retry rispettano la scadenza della richiesta.
  - Nessun retry di chiamate di strumento (NFR6).
  - Copertura del codice nuovo almeno 80%.
- **Ipotesi da verificare:** la resilienza si aggiunge nel layer LLM senza cambiare l'interfaccia `LLMService` usata da tutti.
- **Demo:** un test che simula 429 e un provider giù, con `make runs` che mostra i tentativi.
- **Nota:** accendere il coordinatore in produzione solo dopo questo Bolt.

## Bolt 5 — Voce dal coordinatore (U5)

- **Contiene:** correlation ID dal caricamento del Segment fino al worker voce, chiamata al Coordinator con origine `voice`, messaggio di fallimento di oggi per le esecuzioni interrotte.
- **Definition of Done:** una richiesta vocale crea un'esecuzione con lo stesso correlation ID registrato al caricamento (FR8.2); ramo foto invariato; prova reale con telefono e wearable (Q5); copertura del codice nuovo almeno 80%.
- **Ipotesi da verificare:** la voce ottiene le stesse capacità di Ask senza cambiare wake word, raccolta del comando e verifica.
- **Demo:** "Ehi Echo, cosa mi ha promesso Marco? aggiungilo a Todoist" detto al wearable.

## Bolt 6 — Assistenti come agenti (U6)

- **Contiene:** risoluzione degli assistenti dell'utente come AgentSpec, esecuzione con l'adattatore Azioni e il profilo.
- **Definition of Done:** un utente con due assistenti li vede nell'elenco degli agenti, mai quelli di altri (FR2.3); una richiesta rivolta a un assistente usa le sue istruzioni, note e documenti; copertura del codice nuovo almeno 80%.
- **Ipotesi da verificare:** un assistente è davvero solo un profilo dell'agente Azioni.
- **Demo:** in Ask, "chiedi al coach del sonno…" delega all'assistente Sonno.

## Bolt 7 — Budget giornaliero (U7)

- **Contiene:** `daily_budget_status` in `services/usage.py`, limiti per piano nelle impostazioni, controllo nel Coordinator, costo per agente in `make usage`.
- **Definition of Done:** utente free oltre il budget → nessuna delega, risposta localizzata, il giorno dopo funziona (FR9.2); `make usage` divide il costo per agente (FR9.3); prezzi in `usage_prices.py` verificati prima di fissare i limiti (Q5); copertura del codice nuovo almeno 80%.
- **Ipotesi da verificare:** i costi misurati nei Bolt precedenti bastano a fissare limiti per piano sensati.
- **Demo:** un utente di prova oltre il limite riceve il messaggio, `make usage` mostra il costo per agente.

## Ordine che il sistema seguirà

Questo piano registra il perché dell'ordine. La costruzione segue il DAG di `unit-of-work-dependency.md`, che permette sia U3 prima di U2 sia U2 prima di U3: se il sistema propone U2 prima di U3, l'ordine resta valido perché le due unità non dipendono l'una dall'altra, e l'unica regola che conta (accendere il coordinatore in produzione solo dopo U2) resta vera.
