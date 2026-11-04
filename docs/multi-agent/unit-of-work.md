# Unità di lavoro — Coordinatore multi-agente per Echo

Fonti: `inception/domain-design/components.md` (15 componenti), `inception/domain-design/decisions.md` (ADR-001…ADR-010), `inception/requirements-analysis/requirements.md`, risposte in `units-generation-questions.md` (Q1: codice di base in `app/core/`; Q2: sette unità piccole; piano approvato).

Modello di deploy, uguale per tutte: codice incorporato nel monolite (`api` e `worker`, ADR-001), rilasciato con `make deploy` di oggi, ogni capacità dietro un'impostazione spenta di default (FR11.1). Le migrazioni sono solo additive (FR11.3).

**Modifica rispetto a ADR-008 (decisa in Q1):** RunTracker e RequestBudget vivono in `backend/app/core/`, non in `backend/app/agents/`. `core` non importa nessun altro package dell'app, quindi `actions/`, `services/` e `workers/` possono usarli senza cicli di import (punto R-02 della revisione del Domain Design). `backend/app/agents/` contiene Coordinator, AgentRegistry, MemoryAgent e ActionsAgent.

## Elenco

| Unit ID | Directory | Kind | Complessità | Deploy | Componenti |
|---|---|---|---|---|---|
| U1 | u1-run-foundation | library | M | embedded | RunTracker, RequestBudget, CoreInfrastructure (correlation ID, impostazioni) |
| U2 | u2-llm-resilience | library | M | embedded | LLMProviderLayer, CoreInfrastructure (breaker per provider) |
| U3 | u3-registry-and-actions-agent | library | L | embedded | AgentRegistry, ActionsAgent, ActionAgentLoop, RoutinesEngine |
| U4 | u4-coordinator-ask | service | L | embedded in `api` | Coordinator, MemoryAgent, IntentRouter, QueryEndpoint |
| U5 | u5-voice-coordinator | service | S | embedded in `worker` | VoiceRequests, BackgroundWorker (correlation ID in queue:voice) |
| U6 | u6-assistant-agents | library | S | embedded | AgentRegistry (risoluzione assistenti), ActionsAgent (profilo) |
| U7 | u7-daily-budget | library | S | embedded | UsageAndPlans, Coordinator (controllo del budget) |

## U1 — u1-run-foundation

- **Descrizione:** la base tecnica di tracciamento e budget su cui poggiano tutte le altre unità.
- **Responsabilità:**
  - Tabelle `agent_runs` e `agent_steps` con migrazione additiva; modelli SQLAlchemy.
  - `core/runs.py`: apertura e chiusura di una esecuzione, registrazione dei passi, contesto corrente in ContextVar, scrittura con sessione propria (un errore del tracciamento non fa fallire la richiesta, FR8.6), argomenti oscurati con le funzioni di `actions/audit.py` spostate o riesportate in modo che `core` non importi `actions` (FR8.4).
  - Chiusura delle esecuzioni `running` oltre il timeout complessivo più un minuto come `interrupted` (FR7.6); retention a 30 giorni (NFR8).
  - `core/request_budget.py`: RequestLimits in ContextVar, contatori di passi e token, scadenza (FR9.1).
  - Funzioni per mettere e ripristinare il correlation ID nei payload delle code (FR8.2); impostazioni del coordinatore (interruttori per tappa, tetti, timeout).
  - Comando operatore `make runs` (`app/cli/runs.py`): un'esecuzione per correlation ID, o le ultime N di un utente, con passi e costo stimato (FR8.3).
- **Confini:** nessuna logica di agenti; non chiama LLM; non importa `actions/`, `services/` (tranne i prezzi, che vanno letti senza ciclo), `agents/`, `workers/`.
- **Note:** i prezzi per modello (`usage_prices.py`) sono già un modulo di primo livello senza dipendenze, quindi `core/runs.py` può usarli.

## U2 — u2-llm-resilience

- **Descrizione:** timeout, retry e circuit breaker per provider nel layer LLM, validi anche sul percorso sincrono.
- **Responsabilità:**
  - Breaker per provider in `core/circuit_breaker.py` (LLM OpenAI, STT OpenAI, STT Deepgram) al posto del solo `openai_breaker` condiviso (FR7.4); i worker di oggi passano al breaker del loro provider.
  - Timeout e retry con backoff e jitter per errori transitori nelle chiamate al modello di `llm_openai.py` (FR7.2); ogni tentativo consuma budget (risposta al punto R-02 della revisione).
  - Dopo ogni chiamata: addebito dei token al RequestLimits corrente e passo `llm_call` nel contesto di esecuzione, se presenti (FR8.1).
- **Confini:** non tocca gli strumenti: nessun retry di chiamate con effetti (FR7.3).

## U3 — u3-registry-and-actions-agent

- **Descrizione:** il registro degli agenti e l'agente Azioni come adattatore del ciclo di oggi.
- **Responsabilità:**
  - `agents/registry.py`: AgentSpec per Memoria e Azioni, validazione all'avvio di `api` e `worker` (FR2.1, FR2.2), restrizioni per contesto (FR6.3), interfaccia degli strumenti indipendente dalla sorgente (FR10.2).
  - `agents/actions_agent.py`: AgentTask → `run_action_agent` → AgentResult (FR3.2, FR4.2).
  - `actions/agent.py`: quattro ingressi opzionali — strumenti permessi (rifiuto e registrazione delle chiamate fuori elenco, FR6.1), untrusted iniziale (FR6.4), scadenza, registratore dei passi di strumento. Senza ingressi il comportamento è quello di oggi.
  - `workers/routines.py`: ogni esecuzione di routine apre una esecuzione con origine `routine` (FR8.5).
- **Confini:** policy, pending action, audit e `_LASTING_OWN` non cambiano (FR6.2).

## U4 — u4-coordinator-ask

- **Descrizione:** la chat Ask passa dal coordinatore, con gli agenti Memoria e Azioni.
- **Responsabilità:**
  - `agents/coordinator.py`: percorso veloce senza chiamate in più (FR1.3), piano, esecuzione sequenziale a un livello (FR1.5), propagazione del non fidato, risposte parziali (FR7.5), timeout complessivo, apertura dell'esecuzione e del budget, `usage_owner` (FR4.3).
  - `agents/memory_agent.py`: recupero e una risposta, anche in streaming, risultato non fidato (FR3.1).
  - `actions/availability.py`: DelegationPlan in una chiamata (ADR-002).
  - `routers/query.py`: interruttore del coordinatore; contratto JSON/SSE, idempotenza e salvataggio del turno invariati (FR1.6, FR5.3).
  - Composizione: passa così com'è o una sintesi (ADR-005).
- **Confini:** voce, assistenti e budget giornaliero sono altre unità.

## U5 — u5-voice-coordinator

- **Descrizione:** le richieste vocali "Ehi Echo" passano dal coordinatore (FR1.2).
- **Responsabilità:** `workers/voice_requests.py` chiama il Coordinator con origine `voice`, ramo foto invariato; correlation ID dal caricamento del Segment fino al worker voce (FR8.2); messaggio di fallimento di oggi per esecuzioni interrotte (FR7.6).
- **Confini:** nessun cambiamento a wake word, raccolta del comando e verifica LLM.

## U6 — u6-assistant-agents

- **Descrizione:** gli assistenti dell'utente diventano agenti (FR2.3, FR3.4, ADR-009).
- **Responsabilità:** il registro aggiunge per ogni richiesta un AgentSpec per ciascun assistente dell'utente, letto per `user_id`; l'adattatore Azioni li esegue con il profilo dell'assistente.
- **Confini:** nessun cambiamento ai dati o alle API degli assistenti.

## U7 — u7-daily-budget

- **Descrizione:** budget giornaliero di costo LLM per piano (FR9.2, FR9.4).
- **Responsabilità:** calcolo del costo del giorno da `llm_usage` e `usage_prices.py`, limiti per piano nelle impostazioni (provvisori), controllo nel Coordinator prima di delegare, messaggio localizzato, costo per agente in `make usage` dai passi (FR9.3).
- **Confini:** nessuna tabella nuova; le quote mensili restano fuori.
