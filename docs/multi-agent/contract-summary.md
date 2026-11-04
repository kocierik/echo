# Contratti — Coordinatore multi-agente per Echo

Fonti: `inception/units-generation/unit-of-work.md` e `unit-of-work-dependency.md` (7 unità e il loro DAG), `inception/domain-design/components.md` (entità), `inception/requirements-analysis/requirements.md` (FR e NFR), risposte in `contract-design-questions.md` (Q1 scadenza cooperativa, Q2 addebito dei token in U1 dentro `record_usage`, Q3 stessi eventi SSE di oggi).

Tutti i confini interni sono chiamate Python nello stesso processo (ADR-001): il meccanismo è un **contratto di tipi condivisi** (shared schema), scritto qui come schema YAML dei tipi e delle firme. L'unico confine esterno toccato è `POST /api/query`, che resta compatibile con l'app di oggi.

**Conseguenza di Q2 sul DAG:** l'addebito dei token al RequestLimits e il passo `llm_call` stanno in U1 (in `services/usage.record_usage`, il punto per cui passa già ogni chiamata al modello). U2 resta solo timeout, retry e breaker. Così U4 non ha bisogno di U2 (punto R-02 della revisione di Units Generation) e il DAG approvato non cambia.

## Contratti

| # | Provider Unit | Consumer | Mechanism | Owner |
|---|---|---|---|---|
| C1 | U1 u1-run-foundation | U2, U3, U4, U5, U7, `services/usage.py` | shared schema: API Python `app/core/runs.py` | U1 |
| C2 | U1 u1-run-foundation | U3, U4, `services/usage.py` | shared schema: API Python `app/core/request_budget.py` | U1 |
| C3 | U1 u1-run-foundation | U5, BackgroundWorker | shared schema: campo `correlation_id` nei payload JSON delle code Redis | U1 |
| C4 | U1 u1-run-foundation | U1 (scrittura), `make runs`, U7 (lettura costi) | shared schema: tabelle `agent_runs`, `agent_steps` | U1 |
| C5 | U3 u3-registry-and-actions-agent | U4, U6 | shared schema: tipi `AgentSpec`, `AgentTask`, `AgentResult` e API del registro in `app/agents/types.py`, `app/agents/registry.py` | U3 |
| C6 | U3 u3-registry-and-actions-agent | U3 (adattatore Azioni), RoutinesEngine | shared schema: nuovi parametri opzionali di `run_action_agent` | U3 |
| C7 | U4 u4-coordinator-ask | U5, U7 | shared schema: API Python `app/agents/coordinator.py` | U4 |
| C8 | U4 u4-coordinator-ask | U4 (Coordinator ↔ IntentRouter) | shared schema: JSON del DelegationPlan restituito dal modello | U4 |
| C9 | U7 u7-daily-budget | U4 (Coordinator) | shared schema: funzione `daily_budget_status` in `services/usage.py` | U7 |
| C10 | U2 u2-llm-resilience | tutti i chiamanti di `LLMService` | shared schema: interfaccia `LLMService` invariata più eccezione `ProviderUnavailable` | U2 |
| C11 | U4 u4-coordinator-ask | External: app mobile Echo | REST + SSE (OpenAPI) `POST /api/query`, invariato | U4 |

## C1 — Contesto di esecuzione (`app/core/runs.py`)

```yaml
# shared-schema: app/core/runs.py
module: app.core.runs
import_rule: >
  Importa solo la libreria standard, sqlalchemy, app.core.* (tranne app.core.auth),
  app.models.* e app.usage_prices. Mai app.actions, app.services, app.agents,
  app.workers. Le funzioni di oscuramento vivono in app/core/redaction.py (stessa
  regola); actions/audit.py le importa da lì, non il contrario. Verificato da un test
  di import (U1).
types:
  RunSource: [chat, voice, routine]
  RunStatus: [running, completed, failed, timeout, budget_exceeded, interrupted]
  StepKind: [plan, delegation, llm_call, tool_call, synthesis]
  StepStatus: [ok, failed, refused, timeout, unknown, skipped]
functions:
  - name: open_run
    async: true
    params: {user_id: UUID, source: RunSource, correlation_id: str}
    returns: RunContext
    effect: >
      Inserisce una riga agent_runs con status running in una sessione propria e
      imposta RunContext nella ContextVar current_run. Un errore di scrittura viene
      registrato nei log e restituisce comunque un RunContext (la richiesta prosegue).
  - name: current_run
    params: {}
    returns: RunContext | None
  - name: record_step
    async: true
    params:
      kind: StepKind
      agent_id: str | None
      tool_name: str | None
      tier: "READ | CREATE | CONFIRM | None"
      status: StepStatus
      duration_ms: int
      tokens_in: int
      tokens_out: int
      model: str | None
      attempt: int
      error_class: str | None
      args: dict | None        # oscurati con core.redaction prima di scrivere
      action_log_id: UUID | None
    returns: None
    effect: >
      Aggiunge una riga agent_steps alla esecuzione corrente con seq crescente e costo
      stimato da usage_prices; senza esecuzione corrente non fa nulla. Mai solleva.
  - name: close_run
    async: true
    params: {run: RunContext, status: RunStatus, plan_summary: str | None, error_class: str | None}
    returns: None
  - name: close_interrupted
    async: true
    params: {older_than_seconds: int}
    returns: int               # numero di esecuzioni chiuse come interrupted
    caller: >
      All'avvio di api e worker, e ogni 60 s da un task del worker avviato da
      workers/main.py (owner U1).
  - name: purge_older_than
    async: true
    params: {days: int}        # 30, dal worker di retention
    returns: int
```

## C2 — Tetto della richiesta (`app/core/request_budget.py`)

```yaml
# shared-schema: app/core/request_budget.py
module: app.core.request_budget
import_rule: come C1
types:
  RequestLimits:
    max_steps: int
    max_tokens: int
    deadline: float            # time.monotonic() assoluto
    used_steps: int
    used_tokens: int
functions:
  - name: start_budget
    params: {max_steps: int, max_tokens: int, timeout_seconds: float}
    returns: RequestLimits     # imposta la ContextVar current_budget
  - name: current_budget
    returns: RequestLimits | None
  - name: charge_tokens
    params: {tokens: int}
    caller: services/usage.record_usage, dopo ogni chiamata al modello (Q2)
  - name: charge_step
    params: {}
    caller: ciclo dell'agente Azioni, MemoryAgent, Coordinator (uno per passo LLM o strumento)
  - name: check
    returns: "ok | steps_exhausted | tokens_exhausted | deadline_passed"
    rule: >
      Chiamato prima di ogni chiamata al modello e prima di ogni strumento. Ogni
      tentativo di retry (U2) passa da record_usage, quindi consuma token come gli altri.
```

Scadenza cooperativa (Q1): il ciclo dell'agente e il Coordinator chiamano `check()` prima di ogni chiamata; uno strumento già partito non viene interrotto e finisce con il proprio timeout (Composio 20 s, telefono 25 s); se l'esito è incerto lo stato è `unknown`; dopo, il ciclo restituisce `timeout`. Il timeout complessivo della richiesta (NFR2, 45 s iniziali) è quindi un limite all'inizio di nuove chiamate, non una cancellazione: la durata massima reale è scadenza + timeout dello strumento più lungo (25 s).

## C3 — Correlation ID nelle code

```yaml
# shared-schema: payload delle code Redis
queues: [queue:stt, queue:analysis, queue:voice]
field:
  name: correlation_id
  type: string
  required: false              # i payload senza campo (accodati prima del rilascio) restano validi
functions:
  - name: app.core.logging.with_correlation
    params: {payload: dict}
    returns: dict              # copia del payload con correlation_id corrente
  - name: app.core.logging.restore_correlation
    params: {payload: dict}
    effect: imposta la ContextVar correlation_id dal payload, o ne crea uno nuovo
rule: i consumatori ignorano i campi sconosciuti; nessuno è obbligatorio
```

## C4 — Tabelle del tracciamento

```yaml
# shared-schema: PostgreSQL, migrazione additiva (U1)
agent_runs:
  id: uuid primary key
  correlation_id: text not null, indicizzato
  user_id: uuid null, indicizzato con started_at   # null solo se manca l'utente (mai per chat)
  source: text not null                           # RunSource
  status: text not null                           # RunStatus
  plan_summary: text null                         # solo identificatori di agenti, niente testo dell'utente
  started_at: timestamptz not null
  ended_at: timestamptz null
  tokens_in: integer not null default 0
  tokens_out: integer not null default 0
  cost_usd: numeric(12,6) not null default 0      # stima, mai mostrata come importo fatturato
  error_class: text null
agent_steps:
  id: uuid primary key
  run_id: uuid not null references agent_runs(id) on delete cascade
  seq: integer not null                           # unico per run_id
  kind: text not null                             # StepKind
  agent_id: text null
  tool_name: text null
  tier: text null
  attempt: integer not null default 1
  started_at: timestamptz not null
  duration_ms: integer not null
  tokens_in: integer not null default 0
  tokens_out: integer not null default 0
  cost_usd: numeric(12,6) not null default 0
  status: text not null                           # StepStatus
  error_class: text null
  args_redacted: jsonb null
  action_log_id: uuid null
privacy: nessun corpo di messaggio, nessun testo di risposta, argomenti oscurati come actions/audit.py
retention: 30 giorni (purge_older_than); cancellazione di un account futura dovrà includere agent_runs
```

## C5 — Tipi degli agenti e registro (`app/agents/types.py`, `app/agents/registry.py`)

```yaml
# shared-schema: app/agents/types.py
AgentSpec:
  agent_id: str                 # "memory", "actions", "assistant:<uuid>"
  kind: "code | assistant"
  description: str              # usata nel prompt del piano
  allowed_tools: frozenset[str] # nomi di strumento; "*connected" = app collegate dell'utente
  allowed_tiers: frozenset["READ" | "CREATE" | "CONFIRM"]
  default_limits: {max_steps: int, timeout_seconds: float}
  runner: "memory | actions"
  assistant_id: UUID | None
AgentTask:
  task_id: str
  agent_id: str
  instruction: str              # compito scritto dal piano
  language: "it | en"
  thread_excerpt: list[{role: str, text: str}]   # al più N turni e M caratteri (FR5.1)
  personal_context: str | None  # istruzioni personali, come oggi
  untrusted_in: bool
  stream: "Callable[[str], Awaitable[None]] | None"   # solo per la fonte finale in streaming (Q3)
AgentResult:
  task_id: str
  status: "ok | needs_confirmation | failed | timeout | budget_exceeded | skipped"
  text: str
  sources: list
  pending_action_id: UUID | None
  untrusted_out: bool
  tokens_in: int
  tokens_out: int
  cost_usd: float
registry_api:
  - name: validate_registry
    when: avvio di api e worker
    raises: RegistryError con agent_id e nome dello strumento
  - name: agents_for
    async: true
    params: {db: AsyncSession, user_id: UUID, context: "chat | voice | routine"}
    returns: list[AgentSpec]    # restrizioni per contesto applicate (FR6.3); assistenti in U6
  - name: run_agent
    async: true
    params: {db: AsyncSession, user_id: UUID, spec: AgentSpec, task: AgentTask}
    returns: AgentResult        # non solleva: errori -> status failed
```

## C6 — Nuovi parametri di `run_action_agent`

```yaml
# shared-schema: app/actions/agent.py (tutti opzionali, default = comportamento di oggi)
new_params:
  allowed_tools: frozenset[str] | None   # None = tutti come oggi; fuori elenco -> rifiuto, passo refused, nessuna chiamata al provider
  initial_untrusted: bool = False        # True = _LASTING_OWN bloccati da subito
  respect_budget: bool = False           # True = check() del RequestLimits prima di ogni passo (Q1)
unchanged: classify_tool, classify_call, PendingAction, _LASTING_OWN, AuditRecorder, esiti unknown
step_recording: ogni chiamata di strumento chiama core.runs.record_step con action_log_id
```

## C7 — Coordinatore (`app/agents/coordinator.py`)

```yaml
# shared-schema: app/agents/coordinator.py
function:
  name: coordinate
  async: true
  params:
    db: AsyncSession
    user_id: UUID
    source: "chat | voice"
    question: str
    thread: list               # cronologia già caricata dal chiamante
    assistant_id: UUID | None
    on_token: "Callable[[str], Awaitable[None]] | None"
  returns:
    CoordinatorOutcome:
      text: str
      sources: list
      pending_action: dict | None    # stesso formato di oggi in QueryResponse
      route_kind: "memory | notice | delegate | photo"
      run_status: RunStatus
  rules:
    - percorso veloce senza chiamate di instradamento (FR1.3)
    - esecuzione del piano in ordine; uno step con uses_result_of che punta a uno step failed, timeout o vuoto diventa skipped (R-03 del Domain Design)
    - untrusted_in = OR degli untrusted_out precedenti
    - on_token passato solo alla fonte finale (Memoria sola, o sintesi) (Q3)
    - non solleva per errori di agenti; errori di infrastruttura (DB) risalgono come oggi
    - salvataggio del turno e idempotenza restano al chiamante (FR1.6, FR5.3)
```

## C8 — Piano di delega (output del modello)

```yaml
# shared-schema: JSON restituito da complete_json in actions/availability.py
DelegationPlan:
  route_kind: "memory | notice | delegate | photo"
  reason: string
  steps:                        # vuoto se route_kind != delegate; al più 3
    - agent_id: string          # deve essere in agents_for(...)
      instruction: string
      uses_result_of: integer | null   # indice di uno step precedente, o null
validation:
  - agent_id sconosciuto -> step failed registrato, gli altri proseguono (FR2.4)
  - JSON non valido -> un nuovo tentativo; poi percorso memory
  - uses_result_of che punta in avanti o a sé -> trattato come null
  - campi sconosciuti ignorati
```

## C9 — Budget giornaliero (`services/usage.py`)

```yaml
# shared-schema: app/services/usage.py
function:
  name: daily_budget_status
  async: true
  params: {db: AsyncSession, user_id: UUID}
  returns:
    DailyLlmBudget: {user_id: UUID, day: date, plan: "free | plus | unlimited", limit_usd: float | null, spent_usd: float, exceeded: bool}
  rule: >
    Giorno in UTC come llm_usage; limit_usd null = nessun limite. Il Coordinator la chiama
    prima di delegare; con exceeded vero usa solo il percorso veloce della Memoria.
```

## C10 — `LLMService` con resilienza

```yaml
# shared-schema: app/services/llm_base.py
interface: LLMService      # metodi e firme invariati
new_exception:
  name: ProviderUnavailable
  when: breaker del provider aperto, o tentativi esauriti per errori transitori
  fields: {provider: str, retry_after_seconds: float | None}
retry: solo timeout, 429, 5xx; backoff con jitter; mai per chiamate di strumento
callers_must: >
  Trattare ProviderUnavailable come fallimento del passo (status failed, error_class
  provider_unavailable) e rispondere con il messaggio localizzato.
```

## C11 — `POST /api/query` (invariato)

```yaml
openapi: 3.0.3
info: {title: Echo chat query, version: "invariata"}
paths:
  /api/query:
    post:
      security: [{ApiKey: []}]
      requestBody:
        content:
          application/json:
            schema: {$ref: "#/components/schemas/QueryRequest"}
      responses:
        "200":
          description: QueryResponse intera (risposta non streaming)
          content:
            application/json:
              schema: {$ref: "#/components/schemas/QueryResponse"}
            text/event-stream:
              schema:
                type: string
                description: >
                  Eventi di oggi, nessuno nuovo (Q3): `token` {"text"} solo quando la risposta
                  finale ha una sola fonte in streaming (percorso veloce, Memoria sola, sintesi);
                  poi `done` con QueryResponse intera, oppure `error` {"status","detail"}.
                  Commenti `: keep-alive` durante le deleghe.
        "409": {description: richiesta con lo stesso client_request_id ancora in corso}
components:
  securitySchemes:
    ApiKey: {type: apiKey, in: header, name: X-API-Key}
  schemas:
    QueryRequest: {description: "schema di oggi in routers/query.py, invariato"}
    QueryResponse: {description: "schema di oggi in routers/query.py, invariato; pending_action nello stesso formato"}
```

## Contract ownership rules

- Ogni contratto ha un solo proprietario, l'unità che lo fornisce (tabella sopra). Un cambiamento lo fa il proprietario e aggiorna i consumatori nello stesso commit, perché il repository è uno solo.
- Cambiamenti additivi (un campo opzionale in più, un valore di enum in più) non rompono: i consumatori ignorano i campi sconosciuti (C3, C8) e i parametri nuovi hanno un default che riproduce il comportamento di oggi (C6).
- Cambiamenti che rompono (togliere o rinominare un campo, cambiare il significato di uno stato) richiedono di aggiornare questo documento e i test di contratto dell'unità proprietaria prima del codice.
- C11 è esterno: nessun cambiamento che rompa l'app di oggi (NFR9); un evento SSE nuovo sarebbe un cambiamento che rompe e resta fuori (Q3).
- La regola di import di C1 e C2 è verificata da un test in U1: un modulo di `core` che importa `actions`, `services`, `agents` o `workers` fa fallire la CI.

## Open questions

| Contract | Question | Blocks |
|---|---|---|
| C2 | Valori iniziali di `max_steps`, `max_tokens` e del timeout complessivo (45 s proposti in NFR2) | U4 (NFR Requirements li fissa) |
| C9 | Limiti in USD per piano free/plus/unlimited | U7 (NFR Requirements, dopo la misura dei costi) |
| C5 | Numero massimo di turni e caratteri di `thread_excerpt` | U4 (Functional Design) |
| C10 | Soglie dei breaker per provider e numero di tentativi | U2 (NFR Requirements) |
| C8 | Al più 3 passi per piano: confermare con le eval in italiano | U4 (Functional Design) |
