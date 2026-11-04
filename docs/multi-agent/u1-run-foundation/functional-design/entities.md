# Entità — U1 u1-run-foundation

Fonti: `inception/units-generation/unit-of-work.md` (U1), `inception/contract-design/contract-summary.md` (C1–C4), `inception/domain-design/components.md` (RunTracker, RequestBudget), `inception/requirements-analysis/requirements.md`.

```yaml
entities:
  - name: AgentRun
    description: Una esecuzione registrata — una richiesta gestita dal coordinatore o un'esecuzione di routine.
    persisted: true
    attributes:
      - {name: id, type: identifier, required: true, unique: true, default: generated}
      - {name: correlation_id, type: text, required: true, constraints: "lo stesso dei log della richiesta"}
      - {name: user_id, type: identifier, required: false, constraints: "assente solo per lavoro senza utente; mai assente per chat, voce, routine"}
      - {name: source, type: enum, required: true, allowed: [chat, voice, routine]}
      - {name: status, type: enum, required: true, allowed: [running, completed, failed, timeout, budget_exceeded, interrupted], default: running}
      - {name: plan_summary, type: text, required: false, max: 200, constraints: "solo identificatori di agenti separati da virgola, mai testo dell'utente"}
      - {name: started_at, type: timestamp with zone, required: true}
      - {name: ended_at, type: timestamp with zone, required: false, constraints: "presente se e solo se status non è running"}
      - {name: tokens_in, type: integer, required: true, default: 0, min: 0}
      - {name: tokens_out, type: integer, required: true, default: 0, min: 0}
      - {name: cost_usd, type: decimal, required: true, default: 0, min: 0, constraints: "somma dei costi noti dei passi; stima"}
      - {name: cost_unknown, type: boolean, required: true, default: false, constraints: "vero se almeno un passo ha un modello senza prezzo noto"}
      - {name: error_class, type: text, required: false, max: 64}
    constraints:
      - "ended_at >= started_at quando presente"
      - "status running => ended_at assente"
    relationships:
      - {to: AgentStep, cardinality: one-to-many, direction: "una AgentRun ha zero o più AgentStep; cancellare la run cancella i passi"}

  - name: AgentStep
    description: Un passo di una esecuzione — piano, delega, chiamata al modello, chiamata di strumento o sintesi.
    persisted: true
    attributes:
      - {name: id, type: identifier, required: true, unique: true, default: generated}
      - {name: run_id, type: identifier, required: true, references: AgentRun.id}
      - {name: seq, type: integer, required: true, min: 1, constraints: "unico per run_id, crescente nell'ordine di registrazione"}
      - {name: kind, type: enum, required: true, allowed: [plan, delegation, llm_call, tool_call, synthesis]}
      - {name: agent_id, type: text, required: false, max: 80}
      - {name: tool_name, type: text, required: false, max: 120}
      - {name: model, type: text, required: false, max: 80}
      - {name: tier, type: enum, required: false, allowed: [READ, CREATE, CONFIRM]}
      - {name: attempt, type: integer, required: true, default: 1, min: 1}
      - {name: started_at, type: timestamp with zone, required: true}
      - {name: duration_ms, type: integer, required: true, min: 0}
      - {name: tokens_in, type: integer, required: true, default: 0, min: 0}
      - {name: tokens_out, type: integer, required: true, default: 0, min: 0}
      - {name: cost_usd, type: decimal, required: true, default: 0, min: 0}
      - {name: cost_unknown, type: boolean, required: true, default: false}
      - {name: status, type: enum, required: true, allowed: [ok, failed, refused, timeout, unknown, skipped]}
      - {name: error_class, type: text, required: false, max: 64}
      - {name: args_redacted, type: json, required: false, constraints: "solo per tool_call; chiavi con corpi sostituite dalla lunghezza (BR1.7)"}
      - {name: action_log_id, type: identifier, required: false, constraints: "riga di action_log quando lo strumento è stato registrato nell'audit"}
    relationships:
      - {to: AgentRun, cardinality: many-to-one, direction: "ogni AgentStep appartiene a una sola AgentRun"}

  - name: RunContext
    description: L'esecuzione corrente del task asincrono, tenuta in una ContextVar; non persistita.
    persisted: false
    attributes:
      - {name: run_id, type: identifier, required: false, constraints: "assente quando il tracciamento è spento o la scrittura iniziale è fallita"}
      - {name: correlation_id, type: text, required: true}
      - {name: user_id, type: identifier, required: false}
      - {name: source, type: enum, required: true, allowed: [chat, voice, routine]}
      - {name: next_seq, type: integer, required: true, default: 1}
      - {name: current_agent, type: text, required: false, constraints: "impostato dall'agente in esecuzione; usato per i passi llm_call"}
      - {name: tokens_in, type: integer, required: true, default: 0}
      - {name: tokens_out, type: integer, required: true, default: 0}
      - {name: cost_usd, type: decimal, required: true, default: 0}
      - {name: cost_unknown, type: boolean, required: true, default: false}

  - name: RequestLimits
    description: Il tetto di una richiesta, tenuto in una ContextVar; non persistito.
    persisted: false
    attributes:
      - {name: run_id, type: identifier, required: false, references: AgentRun.id}
      - {name: max_steps, type: integer, required: true, min: 1}
      - {name: max_tokens, type: integer, required: true, min: 1}
      - {name: deadline, type: monotonic instant, required: true}
      - {name: used_steps, type: integer, required: true, default: 0, min: 0}
      - {name: used_tokens, type: integer, required: true, default: 0, min: 0}
    relationships:
      - {to: AgentRun, cardinality: zero-or-one-to-one, direction: "un RequestLimits appartiene al più a una AgentRun"}
```

## Sintesi

- **AgentRun** e **AgentStep** sono le uniche entità salvate: due tabelle nuove (`agent_runs`, `agent_steps`) con migrazione additiva; cancellare una run cancella i suoi passi.
- **RunContext** e **RequestLimits** vivono solo in memoria, per la durata di una richiesta o di una routine, in ContextVar come `usage_owner` oggi. Sono oggetti mutabili: i task figli creati con `asyncio.create_task` ereditano la ContextVar e aggiornano lo stesso oggetto.
- Rispetto a C4 di `contract-summary.md` si aggiungono `model` e `cost_unknown` (cambiamento additivo): un modello senza prezzo noto non viene mai contato come gratuito.
