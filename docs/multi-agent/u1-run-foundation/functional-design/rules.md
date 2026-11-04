# Regole — U1 u1-run-foundation

Fonti: `inception/requirements-analysis/requirements.md` (FR e NFR), `inception/contract-design/contract-summary.md` (C1–C4 e i punti R-01, R-02 della sua revisione), `inception/units-generation/unit-of-work.md`.

```yaml
rules:
  # BR1 — esecuzioni e passi
  - id: BR1.1
    statement: Una esecuzione si apre solo dove parte lavoro nuovo (coordinatore, routine); una risposta servita dal marker di idempotenza query:req non apre nessuna esecuzione.
    category: policy
    applies_to: AgentRun
    trigger: richiesta al coordinatore o esecuzione di routine
    logic: IF il lavoro parte davvero THEN open_run con status running, correlation_id corrente e user_id; ELSE nessuna run
    violation: due run per la stessa richiesta
    source: FR8.1
  - id: BR1.2
    statement: Lo stato di una run passa solo da running a uno stato finale, una volta sola; gli stati finali non cambiano più.
    category: constraint
    applies_to: AgentRun.status
    trigger: close_run, close_interrupted
    logic: IF status = running THEN imposta lo stato finale ed ended_at; ELSE ignora la chiusura e lo registra nei log
    violation: una run chiusa due volte mantiene il primo stato finale
    source: FR8.1
  - id: BR1.3
    statement: Ogni passo riceve il numero seq successivo della sua run, assegnato in memoria nell'ordine di registrazione.
    category: constraint
    applies_to: AgentStep.seq
    trigger: record_step
    logic: seq = RunContext.next_seq; poi next_seq + 1
    violation: non applicabile (assegnato dal codice)
    source: FR8.1
  - id: BR1.4
    statement: Senza esecuzione corrente, registrare un passo non fa nulla.
    category: policy
    applies_to: record_step
    trigger: record_step fuori da una run (worker di oggi, test)
    logic: IF current_run assente o senza run_id THEN ritorna senza scrivere
    violation: nessuna
    source: FR8.1
  - id: BR1.5
    statement: Un errore del tracciamento non fa mai fallire il lavoro dell'utente.
    category: policy
    applies_to: open_run, record_step, close_run, close_interrupted
    trigger: errore di database o di serializzazione nel tracciamento
    logic: IF la scrittura fallisce THEN registra l'errore nei log con il correlation_id e continua; open_run restituisce comunque un RunContext senza run_id
    violation: la richiesta prosegue; la run manca o è incompleta
    source: FR8.6
  - id: BR1.6
    statement: Il tracciamento scrive con una sessione propria e un commit proprio, così sopravvive al rollback della richiesta.
    category: policy
    applies_to: open_run, record_step, close_run
    trigger: ogni scrittura
    logic: usa una nuova sessione dalla session factory, commit a ogni operazione
    violation: nessuna
    source: FR8.6
  - id: BR1.7
    statement: Gli argomenti degli strumenti si salvano oscurati; nessun corpo di messaggio né testo di risposta entra nel tracciamento.
    category: policy
    applies_to: AgentStep.args_redacted, AgentRun.plan_summary
    trigger: record_step con args, close_run con plan_summary
    logic: per ogni chiave, IF il nome contiene body, text, content, message, markdown o html (e non finisce in _id/_ids) THEN valore = "(N chars)"; ELSE primi 80 caratteri; al più 300 caratteri totali; plan_summary contiene solo identificatori di agenti
    violation: non applicabile (oscuramento applicato prima della scrittura)
    source: FR8.4
  - id: BR1.8
    statement: Il costo di un passo è una stima dai prezzi per modello; un modello senza prezzo noto lascia il costo a 0 e segna cost_unknown, mai "gratis" senza segnalarlo.
    category: calculation
    applies_to: AgentStep.cost_usd, AgentRun.cost_usd
    trigger: record_step con token e modello
    logic: IF il modello ha un prezzo in usage_prices THEN cost = token × prezzo; ELSE cost = 0 e cost_unknown = vero; la run somma i costi noti e diventa cost_unknown se un passo lo è
    violation: nessuna
    source: FR8.1
  - id: BR1.9
    statement: Le funzioni di oscuramento vivono in core e actions/audit.py le importa da lì; i moduli core.runs, core.request_budget e core.redaction non importano actions, services, agents né workers.
    category: constraint
    applies_to: confini dei package
    trigger: ogni build (test di import in CI)
    logic: IF un modulo vietato compare tra gli import THEN il test fallisce
    violation: CI rossa
    source: FR8.4

  # BR2 — esecuzioni interrotte
  - id: BR2.1
    statement: Una run ancora running oltre la soglia di esecuzione interrotta viene chiusa come interrupted.
    category: policy
    applies_to: AgentRun.status
    trigger: close_interrupted
    logic: IF status = running AND started_at < adesso - soglia THEN status = interrupted, ended_at = adesso, error_class = interrupted
    violation: nessuna
    source: FR7.6
  - id: BR2.2
    statement: La soglia è la durata massima reale di una richiesta più 60 secondi, come impostazione, inizialmente 180 secondi.
    category: constraint
    applies_to: impostazione run_interrupted_after_seconds
    trigger: configurazione
    logic: durata massima reale = timeout complessivo (45 s) + timeout dello strumento più lungo (25 s) + una chiamata al modello già partita (fino a 30 s, fissata da U2) ≈ 100 s; soglia = 100 + 60 arrotondato a 180
    violation: un valore minore della durata massima reale chiuderebbe run ancora vive; all'avvio si registra un avviso se soglia < timeout complessivo + 85 s
    source: FR7.6
  - id: BR2.3
    statement: La chiusura delle interrotte gira all'avvio di api e worker e poi ogni 60 secondi in un task del worker; è idempotente.
    category: policy
    applies_to: close_interrupted
    trigger: avvio dei processi, timer del worker
    logic: una sola UPDATE condizionata su status = running; ripeterla non cambia run già chiuse
    violation: nessuna
    source: FR7.6

  # BR3 — tetto della richiesta
  - id: BR3.1
    statement: Il tetto vale solo dentro una richiesta che lo ha aperto; senza tetto corrente, addebiti e controlli non fanno nulla.
    category: policy
    applies_to: RequestLimits
    trigger: charge_tokens, charge_step, check
    logic: IF current_budget assente THEN charge = nessun effetto, check = ok
    violation: nessuna (il comportamento di oggi resta identico)
    source: FR9.1
  - id: BR3.2
    statement: Solo le chiamate di completamento del modello consumano il tetto di token; embedding, trascrizioni, impronte vocali e ricerche web no.
    category: calculation
    applies_to: charge_tokens
    trigger: record_usage
    logic: IF kind inizia con llm_ THEN used_tokens += input_units + output_units; ELSE nessun addebito
    violation: nessuna
    source: FR9.1
  - id: BR3.3
    statement: Ogni chiamata al modello e ogni chiamata di strumento consumano un passo.
    category: calculation
    applies_to: charge_step
    trigger: prima di una chiamata al modello o di uno strumento, dopo un check ok
    logic: used_steps += 1
    violation: nessuna
    source: FR9.1
  - id: BR3.4
    statement: Il controllo restituisce il primo limite superato in quest'ordine — scadenza, token, passi — oppure ok.
    category: validation
    applies_to: check
    trigger: prima di ogni chiamata al modello e di ogni strumento
    logic: IF adesso >= deadline THEN deadline_passed; ELSE IF used_tokens >= max_tokens THEN tokens_exhausted; ELSE IF used_steps >= max_steps THEN steps_exhausted; ELSE ok
    violation: il chiamante non inizia la chiamata e restituisce timeout o budget_exceeded
    source: FR7.1
  - id: BR3.5
    statement: Una chiamata già partita finisce e i suoi token si addebitano anche se superano il tetto; il superamento massimo è quindi una chiamata.
    category: policy
    applies_to: RequestLimits
    trigger: fine di una chiamata partita con check ok
    logic: addebita sempre; il check successivo ferma il lavoro
    violation: nessuna
    source: FR9.1
  - id: BR3.6
    statement: L'addebito dei token e il passo llm_call avvengono fuori dal blocco che ignora gli errori di scrittura di record_usage, così un errore su llm_usage non salta l'addebito.
    category: policy
    applies_to: record_usage
    trigger: ogni chiamata al modello
    logic: charge_tokens e record_step prima della scrittura su llm_usage, ciascuno protetto separatamente
    violation: nessuna
    source: FR8.1
  - id: BR3.7
    statement: Il passo llm_call prende l'agente da RunContext.current_agent, il modello e i token dagli argomenti di record_usage, la durata e il tentativo da due nuovi argomenti opzionali (duration_ms, attempt) passati dal layer LLM.
    category: constraint
    applies_to: record_usage
    trigger: ogni chiamata al modello
    logic: argomenti assenti → duration_ms = 0, attempt = 1
    violation: nessuna
    source: FR8.1

  # BR4 — correlation ID
  - id: BR4.1
    statement: I produttori di queue:stt, queue:analysis e queue:voice aggiungono al payload il correlation_id corrente.
    category: policy
    applies_to: payload delle code
    trigger: lpush su quelle code
    logic: payload = with_correlation(payload)
    violation: nessuna
    source: FR8.2
  - id: BR4.2
    statement: I consumatori ripristinano il correlation_id dal payload prima di elaborare; un payload senza il campo ne riceve uno nuovo.
    category: policy
    applies_to: worker delle code
    trigger: brpop/rpop
    logic: restore_correlation(payload)
    violation: nessuna (i payload accodati prima del rilascio restano validi)
    source: FR8.2

  # BR5 — impostazioni e rilascio
  - id: BR5.1
    statement: Il tracciamento ha un interruttore spento di default; spento, open_run restituisce un RunContext senza run_id e nulla viene scritto.
    category: policy
    applies_to: impostazione run_tracking_enabled
    trigger: open_run
    logic: IF run_tracking_enabled = falso THEN nessuna scrittura
    violation: nessuna
    source: FR11.1
  - id: BR5.2
    statement: Le tabelle nuove arrivano con una migrazione solo additiva e annullabile; nessuna tabella o colonna esistente cambia.
    category: constraint
    applies_to: migrazione di U1
    trigger: deploy
    logic: crea agent_runs e agent_steps con i loro indici; downgrade le elimina
    violation: revisione della migrazione
    source: FR11.3
  - id: BR5.3
    statement: Le righe di tracciamento più vecchie di 30 giorni si cancellano nel loop di retention esistente.
    category: policy
    applies_to: AgentRun
    trigger: run_retention_loop
    logic: DELETE agent_runs WHERE started_at < adesso - 30 giorni (i passi seguono per cascade)
    violation: nessuna
    source: FR8.1

  # BR6 — comando operatore
  - id: BR6.1
    statement: make runs mostra una run per correlation ID, oppure le ultime N run di un utente (per email o id, N predefinito 10), con i passi e il costo stimato.
    category: policy
    applies_to: app/cli/runs.py
    trigger: comando dell'operatore nel container
    logic: correlation_id → run e passi; utente → ultime N run in ordine di started_at decrescente, poi seq; il costo mostra "stima" e "(costo parziale)" se cost_unknown
    violation: argomenti mancanti o utente inesistente → messaggio chiaro e uscita con codice diverso da 0
    source: FR8.3
```

## Sintesi delle regole

| ID | Regola | Categoria | Fonte |
|---|---|---|---|
| BR1.1 | Run solo per lavoro nuovo, non per risposte già salvate | policy | FR8.1 |
| BR1.2 | Stato finale una volta sola | constraint | FR8.1 |
| BR1.3 | seq crescente per run | constraint | FR8.1 |
| BR1.4 | Nessuna run corrente, nessun passo | policy | FR8.1 |
| BR1.5 | Errori del tracciamento non fanno fallire la richiesta | policy | FR8.6 |
| BR1.6 | Sessione e commit propri | policy | FR8.6 |
| BR1.7 | Argomenti oscurati, niente testi | policy | FR8.4 |
| BR1.8 | Costo stimato, prezzo ignoto segnalato | calculation | FR8.1 |
| BR1.9 | core non importa actions, services, agents, workers | constraint | FR8.4 |
| BR2.1 | running oltre soglia → interrupted | policy | FR7.6 |
| BR2.2 | Soglia = durata massima reale + 60 s (180 s) | constraint | FR7.6 |
| BR2.3 | Chiusura all'avvio e ogni 60 s, idempotente | policy | FR7.6 |
| BR3.1 | Nessun tetto corrente, nessun effetto | policy | FR9.1 |
| BR3.2 | Solo i kind llm_ consumano token | calculation | FR9.1 |
| BR3.3 | Un passo per chiamata al modello o strumento | calculation | FR9.1 |
| BR3.4 | Controllo: scadenza, token, passi | validation | FR7.1 |
| BR3.5 | Superamento massimo di una chiamata | policy | FR9.1 |
| BR3.6 | Addebito fuori dal blocco che ignora gli errori | policy | FR8.1 |
| BR3.7 | Parametri del passo llm_call | constraint | FR8.1 |
| BR4.1 | Produttori aggiungono il correlation_id | policy | FR8.2 |
| BR4.2 | Consumatori lo ripristinano | policy | FR8.2 |
| BR5.1 | Interruttore spento di default | policy | FR11.1 |
| BR5.2 | Migrazione additiva | constraint | FR11.3 |
| BR5.3 | Retention 30 giorni | policy | FR8.1 |
| BR6.1 | make runs | policy | FR8.3 |
