# Decisioni di architettura — Coordinatore multi-agente

Registro delle decisioni prese nel Domain Design. Ogni ADR cita i requisiti di `inception/requirements-analysis/requirements.md` e i componenti di `components.md`. Le implicazioni di sicurezza sono indicate in ogni decisione.

| ADR | Titolo | Stato |
|---|---|---|
| ADR-001 | Coordinatore e agenti nello stesso processo | Accepted |
| ADR-002 | Piano di delega in una chiamata, estendendo route_request | Accepted |
| ADR-003 | Agente Azioni come adattatore di run_action_agent | Accepted |
| ADR-004 | Agente Memoria come recupero più una risposta | Accepted |
| ADR-005 | Risposta: passa così com'è o sintesi se più agenti | Accepted |
| ADR-006 | Permessi: elenco chiuso per agente e flag non fidato propagato | Accepted |
| ADR-007 | Tracciamento in tabelle proprie con contesto in ContextVar | Accepted |
| ADR-008 | Package app/agents, budget per richiesta in memoria, budget giornaliero nei piani | Accepted |
| ADR-009 | Assistants come profili dell'agente Azioni | Accepted |
| ADR-010 | Resilienza nel layer LLM, breaker per provider, nessun retry degli effetti | Accepted |

## ADR-001: Coordinatore e agenti nello stesso processo

### Status: Accepted

### Context
Echo è un monolite modulare su un solo host (`architecture.md`): `api` e `worker` condividono il package `app`, senza RPC interne. La richiesta chiede di evitare complessità inutile (A1, NFR11). Il coordinatore deve servire la chat sincrona (latenza, NFR1) e il worker voce.

### Decision
Coordinator, AgentRegistry, gli agenti, RequestBudget e RunTracker sono moduli Python chiamati come funzioni nello stesso processo di chi li usa (`api` per Ask, `worker` per voce e routine). Nessun nuovo container, coda o servizio.

### Consequences
- Positive: nessuna latenza di rete aggiunta; transazioni e ContextVar (usage_owner, correlation ID) funzionano come oggi; deploy invariato; test con i fake esistenti.
- Negative: un agente lento occupa il processo che lo chiama; non si scalano gli agenti separatamente; le esecuzioni muoiono con il processo (accettato: FR7.6).
- Sicurezza: il confine di fiducia resta quello di oggi (un processo con l'utente autenticato); nessuna nuova superficie di rete da proteggere.

### Alternatives Rejected
- Servizio coordinatore separato con API interna: isolamento e scalabilità propri, ma una rete e un'autenticazione interne in più per un solo host in beta.
- Deleghe come job su code Redis consumati dal worker: disaccoppia nel tempo, ma la chat sincrona dovrebbe attendere un job e la durabilità vera è fuori ambito (Q6 dei requisiti).

## ADR-002: Piano di delega in una chiamata, estendendo route_request

### Status: Accepted

### Context
Oggi `availability.route_request` fa una chiamata `complete_json` che sceglie tra memory/notice/agent/photo. Il coordinatore deve scegliere tra agenti e gestire richieste composte (FR1.4) con una sola chiamata di instradamento (NFR3) e tetti di costo garantiti (FR9.1). Risposta Q1: A.

### Decision
L'IntentRouter riceve dal Coordinator l'elenco degli AgentSpec disponibili e restituisce in una chiamata un DelegationPlan: tipo di percorso, agenti in ordine con un compito ciascuno, motivo. Il Coordinator esegue il piano nel codice, in sequenza. Il pre-filtro a parole chiave resta e decide il percorso veloce (FR1.3). Un agente fuori elenco nel piano diventa un passo fallito (FR2.4).

### Consequences
- Positive: una chiamata per richiesta delegata; numero di passi noto prima di eseguire; piano registrabile e testabile con le eval in italiano esistenti (`evals/`).
- Negative: il piano non si adatta a un risultato inatteso a metà (es. la Memoria non trova nulla e l'Azioni parte lo stesso); si compensa con regole del Coordinator (salta i passi successivi se un passo da cui dipendono fallisce o è vuoto).
- Sicurezza: il piano non decide mai le conferme, che restano nella policy (ROADMAP Fase 7); un piano manipolato da contenuto non fidato non può aggiungere permessi, perché i permessi vengono dal registro (ADR-006).

### Alternatives Rejected
- Coordinatore con tool calling (ogni agente è uno strumento): adattivo, ma una chiamata in più per ogni giro e tetti di costo difficili da garantire.
- Solo regole a parole chiave: zero chiamate, ma non gestisce richieste composte né la scelta tra assistenti.

## ADR-003: Agente Azioni come adattatore di run_action_agent

### Status: Accepted

### Context
`run_action_agent` contiene la logica più delicata: classificazione READ/CREATE/CONFIRM, pending action, `_LASTING_OWN`, audit che sopravvive al rollback, esiti `unknown`. È già parametrizzato per contesto (source, routine_tools, allow_confirm, assistant). Risposta Q3: A.

### Decision
ActionsAgent è un adattatore sottile che traduce AgentTask in una chiamata a `run_action_agent`. Il ciclo (ActionAgentLoop) riceve quattro ingressi nuovi e opzionali: elenco di strumenti permessi, flag untrusted iniziale, scadenza, registratore dei passi. Senza questi ingressi si comporta come oggi, quindi le routine e la tappa spenta non cambiano.

### Consequences
- Positive: le conferme non vengono riscritte; i test di oggi sull'agente restano validi; la prima tappa è piccola.
- Negative: Memoria e Azioni non condividono un ciclo comune; se un giorno serviranno più agenti a ciclo, si estrarrà allora (decisione reversibile).
- Sicurezza: il solo punto con effetti resta uno, e la nuova restrizione (elenco chiuso) si applica prima di contattare il provider.

### Alternatives Rejected
- Estrarre un ciclo generico per tutti gli agenti: più ordinato, ma tocca conferme e audit nella prima tappa, che è dove il rischio di regressioni è più alto.

## ADR-004: Agente Memoria come recupero più una risposta

### Status: Accepted

### Context
Il percorso di oggi per le domande sulla memoria è recupero senza LLM più una chiamata di risposta. NFR1 e NFR3 vietano di peggiorare latenza e numero di chiamate. Risposta Q2: A.

### Decision
MemoryAgent chiama `retrieve_memory_context` e una sola chiamata di risposta (anche in streaming), senza ciclo. La ricerca web è disponibile solo se è nel suo elenco di strumenti.

### Consequences
- Positive: costo e latenza identici a oggi; il percorso veloce e il compito di memoria in un piano sono lo stesso codice.
- Negative: una domanda che richiederebbe più ricerche successive ottiene una sola ricerca; si potrà passare a un mini-agente misurando prima il beneficio.
- Sicurezza: solo lettura per costruzione; il risultato è sempre marcato non fidato (ADR-006).

### Alternatives Rejected
- Mini-agente con tool calling sugli strumenti di memoria (riusando quelli MCP): più ricerche, ma almeno una chiamata in più per domanda.

## ADR-005: Risposta: passa così com'è o sintesi se più agenti

### Status: Accepted

### Context
Il Coordinator deve dare una sola risposta (FR1.4) senza aggiungere chiamate nel caso comune (NFR3). Risposta Q4: A.

### Decision
Con un agente solo, la sua risposta (testo, fonti, pending_action) passa così com'è. Con più agenti, una chiamata di sintesi unisce i risultati; se un agente è fallito o in timeout, la sintesi lo dichiara (FR7.5). Se la sintesi stessa fallisce, i risultati vengono uniti dal codice in ordine.

### Consequences
- Positive: nessuna chiamata in più per le richieste con un agente; risposta naturale per quelle composte.
- Negative: il tono può variare tra risposte di agenti diversi.
- Sicurezza: la sintesi riceve i risultati come dati delimitati e non può chiamare strumenti; una pending_action resta legata all'agente che l'ha creata e passa all'app invariata.

### Alternatives Rejected
- Sempre una sintesi: tono uniforme, una chiamata in più a ogni delega.
- Unione nel codice senza sintesi: zero chiamate, risposta meno naturale per le richieste composte.

## ADR-006: Permessi: elenco chiuso per agente e flag non fidato propagato

### Status: Accepted

### Context
Risposta Q7 dei requisiti: C. La revisione dei requisiti (R-01) chiedeva quali fonti sono non fidate e cosa blocca il flag. Oggi `run_action_agent` imposta `untrusted` dopo `search_memory`, dopo strumenti esterni e dopo citazioni web; dopo, rifiuta solo gli strumenti propri duraturi (`_LASTING_OWN`: creare/cancellare routine, note degli assistenti, dimenticare fatti, modificare/rimuovere Saved). Creare un task resta permesso; inviare, modificare e cancellare verso altri chiedono sempre Confirm.

### Decision
1. Ogni AgentSpec ha un elenco chiuso di strumenti e di livelli permessi; ActionAgentLoop rifiuta e registra una chiamata fuori elenco senza contattare il provider (FR6.1).
2. Il registro toglie permessi in base al contesto: nelle routine niente livello CONFIRM e niente strumenti di routine (FR6.3).
3. Il flag non fidato segue le stesse fonti di oggi: ogni risultato della MemoryAgent, di strumenti esterni e della ricerca web è untrusted_out. Il Coordinator passa untrusted_in a tutti i compiti successivi della stessa richiesta, e ActionAgentLoop parte con untrusted già vero. L'effetto è quello di oggi, esteso alla delega: dopo contenuti non fidati sono rifiutati gli strumenti propri duraturi, mentre le azioni verso altri restano pending_action. L'esempio "promessa di Marco → Todoist" quindi crea il task come oggi.
4. Il piano (ADR-002) non può concedere strumenti: viene dal modello, i permessi vengono dal registro.

### Consequences
- Positive: un solo significato di "non fidato" in tutto Echo; il criterio di FR1.4 e quello di FR6.4 non si contraddicono più; i permessi sono verificabili in un punto.
- Negative: dopo una lettura dalla memoria, l'utente non può far creare una routine nella stessa richiesta (come oggi): deve chiederlo direttamente.
- Sicurezza: è la difesa principale contro la prompt injection da email e messaggi tra agenti. Il rischio residuo (una creazione immediata, livello CREATE, guidata da contenuto letto) è lo stesso di oggi ed è limitato a strumenti senza destinatari esterni.

### Alternatives Rejected
- Ogni scrittura dopo contenuto non fidato passa da pending_action: più restrittivo, ma cambierebbe il comportamento di oggi e renderebbe confermabile anche creare un task dalla propria memoria.
- Memoria considerata fidata: semplice, ma la memoria contiene parole di altre persone trascritte, quindi aprirebbe un canale di injection che oggi è chiuso.

## ADR-007: Tracciamento in tabelle proprie con contesto in ContextVar

### Status: Accepted

### Context
Risposte Q6 (B) e Q8 (A) dei requisiti: esecuzioni e passi registrati in Postgres, consultabili con un comando operatore, senza ripresa. Esistono già `action_log` (audit delle azioni, redatto, con semantica di conferma) e `llm_usage` (consumo giornaliero aggregato per utente/kind/model).

### Decision
Due tabelle nuove, `agent_runs` e `agent_steps`, con migrazione additiva (FR11.3). Il contesto di esecuzione corrente vive in una ContextVar, come `usage_owner`, così il layer LLM e il ciclo dell'agente registrano i passi senza parametri ovunque. La scrittura usa una sessione propria (sopravvive al rollback della richiesta e non la fa fallire, FR8.6). Gli argomenti sono oscurati con le funzioni di `actions/audit.py`; un passo di strumento punta alla riga di `action_log` quando esiste. Le esecuzioni ancora running oltre il timeout complessivo più un minuto diventano interrupted, all'avvio dei processi e ogni minuto nel worker (FR7.6, R-04 della revisione). Retention 30 giorni nel worker di retention.

### Consequences
- Positive: audit e consumo esistenti restano invariati; costo per agente calcolabile dai passi (FR9.3); un solo correlation ID collega log, esecuzione e passi.
- Negative: una scrittura per passo; con molti utenti servirebbe raggruppare le scritture (A4 lo esclude per ora).
- Sicurezza: nessun corpo di messaggio nel tracciamento; ogni riga ha user_id e il comando operatore è solo per l'operatore. Non esistendo oggi la cancellazione di un account, le righe di un utente seguono la retention di 30 giorni; quando la cancellazione esisterà dovrà includere queste tabelle (R-05 della revisione).

### Alternatives Rejected
- Estendere `action_log` con i passi: mescola l'audit delle azioni confermabili con dati operativi, e cambierebbe una tabella che le conferme usano.
- Solo log strutturati: niente tabelle, ma niente costo per agente né consultazione per utente.

## ADR-008: Package app/agents, budget per richiesta in memoria, budget giornaliero nei piani

### Status: Accepted

### Context
Risposta Q5: A. FR9.1 chiede un tetto di passi e token per richiesta; FR9.2 un budget giornaliero per piano; FR9.4 valori modificabili e provvisori.

### Decision
Il codice nuovo vive in `backend/app/agents/` (Coordinator, AgentRegistry, MemoryAgent, ActionsAgent, RequestBudget, RunTracker); `actions/` resta l'interno dell'agente Azioni. RequestBudget è un oggetto in memoria per la durata della richiesta, consumato da coordinatore, agenti e layer LLM. Il budget giornaliero sta in `services/usage.py` e `services/plans.py`, calcolato da `llm_usage` e `usage_prices.py`, con limiti per piano nelle impostazioni. Superato il budget giornaliero, il Coordinator non delega e risponde solo con il percorso veloce della Memoria (R-03 della revisione: la Memoria resta disponibile; il suo costo è conteggiato ma non bloccato). Routine e voce a budget esaurito: le routine vengono saltate con esito `skipped` come oggi per i piani; la voce segue il comportamento della chat.

### Consequences
- Positive: il coordinatore si legge in una cartella; piani e prezzi restano in un posto solo; nessuna tabella per i budget.
- Negative: il budget giornaliero è una stima basata su prezzi da verificare (A6); la risposta della Memoria oltre budget continua a costare.
- Sicurezza: il budget protegge anche da un uso abusivo di una chiave rubata, limitando il costo giornaliero per utente.

### Alternatives Rejected
- Tutto in `actions/`: meno cartelle, ma coordinatore e un agente specifico mescolati.
- Una tabella di budget con contatori: precisa, ma duplica `llm_usage`.

## ADR-009: Assistants come profili dell'agente Azioni

### Status: Accepted

### Context
Gli Assistants esistono già nel database e oggi la loro chat passa sempre da `run_action_agent` con il parametro `assistant` (istruzioni, note, documenti). FR2.3 e FR3.4 li vogliono come agenti nella tappa Assistants.

### Decision
Per ogni richiesta l'AgentRegistry aggiunge un AgentSpec per ciascun assistente dell'utente (letto per user_id), con runner l'ActionsAgent e il profilo dell'assistente. Nessun componente separato.

### Consequences
- Positive: nessun codice duplicato; un assistente cancellato o di un altro utente non compare mai, perché l'elenco si costruisce a ogni richiesta dall'utente autenticato.
- Negative: l'elenco degli agenti cresce con gli assistenti (al massimo 10), quindi il prompt del piano cresce.
- Sicurezza: un assistente eredita le restrizioni dell'agente Azioni più quelle del suo profilo; non può avere più strumenti dell'agente Azioni.

### Alternatives Rejected
- Un componente AssistantAgent separato: duplicherebbe l'adattatore senza differenze di comportamento.

## ADR-010: Resilienza nel layer LLM, breaker per provider, nessun retry degli effetti

### Status: Accepted

### Context
Oggi `retry_with_backoff` e `openai_breaker` valgono solo nei worker, e il breaker è condiviso con Deepgram. Il percorso sincrono non ha timeout né retry (FR7.2, FR7.4). Gli strumenti con effetti non devono mai essere ripetuti (FR7.3, NFR6).

### Decision
Timeout, retry con backoff e jitter per errori transitori, e un circuit breaker per provider (LLM OpenAI, STT OpenAI, STT Deepgram) vivono nel LLMProviderLayer, così valgono per tutti i chiamanti, sincroni e no. Il retry riguarda solo le chiamate al modello; le chiamate di strumento passano da ActionAgentLoop e non vengono ripetute, con esito `unknown` quando incerto, come oggi. Le soglie si fissano in NFR Requirements.

### Consequences
- Positive: un guasto di Deepgram non blocca più la chat; la chat fallisce in fretta a breaker aperto.
- Negative: i breaker restano per processo (più repliche fuori ambito); un retry aumenta la latenza nei casi di errore, entro la scadenza della richiesta.
- Sicurezza: nessuna azione verso altri ripetuta per errore; i retry rispettano il budget della richiesta, quindi non moltiplicano i costi oltre il tetto.

### Alternatives Rejected
- Retry e timeout in ogni agente: duplicazione e regole diverse per lo stesso provider.
- Un solo breaker globale come oggi: un guasto di un provider spegne anche gli altri.
