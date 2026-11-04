# Component Inventory — Echo

Ogni componente è un titolo `###`; i nomi sono identificatori stabili usati anche nel blocco Scope of Analysis.

## Componenti di backend

### API Server
- **Percorso**: `backend/app/main.py`, `backend/app/routers/`
- **Responsabilità**: app FastAPI, 27 router sotto `/api`, CORS, middleware correlation ID + metriche HTTP, `/health`, `/api/stats`, `/metrics`, montaggio di `/mcp`; pool Redis condiviso in `app.state.redis` (lifespan) e preload dell'SDK Composio.
- **Dipende da**: Core Infrastructure, Action Agent, Intent Router, Memory and RAG, Chat History, MCP Server, Usage and Plans, Data Model and Migrations.

### Core Infrastructure
- **Percorso**: `backend/app/core/`
- **Responsabilità**: `Settings` (`config.py`), engine/sessioni async (`database.py`), autenticazione a chiavi con scope `full`/`read` e token operatore (`auth.py`), log JSON con `correlation_id` ContextVar (`logging.py`), metriche in memoria (`metrics.py`), rate limiter slowapi (`rate_limit.py`), `CircuitBreaker` e `openai_breaker` globale (`circuit_breaker.py`), timezone utente (`timezone.py`).
- **Dipende da**: PostgreSQL, Redis, `services/usage.usage_owner`.

### Action Agent
- **Percorso**: `backend/app/actions/agent.py`, `policy.py`, `pending.py`, `audit.py`
- **Responsabilità**: `run_action_agent` — loop di tool calling (max 6 passi) con `search_memory`, tool propri `ECHO_*` e tool esterni; classificazione `ToolTier` READ/CREATE/CONFIRM (`classify_tool`, `classify_call` con chiavi "persone"); prima chiamata CONFIRM → `PendingAction` (TTL 30 min) e stop; `allow_confirm=False` per le routine; guardia `untrusted` che blocca i tool "duraturi" (`_LASTING_OWN`) dopo aver letto contenuti non scritti dall'utente; audit redatto (`log_action`, `AuditRecorder`, `restore_audit`); risposta finale che dichiara i fallimenti e gli esiti sconosciuti (`_final_answer`).
- **Dipende da**: LLM Provider Layer, Action Providers, Agent Own Tools, Memory and RAG, Assistants, `services/personal.py`, `services/web_search.py`.

### Agent Own Tools
- **Percorso**: `backend/app/actions/routine_tools.py`, `todo_tools.py`, `saved_tools.py`, `fact_tools.py`, `assistant_tools.py`
- **Responsabilità**: schemi e handler degli strumenti interni (`ECHO_CREATE_ROUTINE`, `ECHO_LIST_ROUTINES`, `ECHO_DELETE_ROUTINE`, `ECHO_CREATE_TASK`, `ECHO_SAVE_ITEM`, `ECHO_UPDATE_ITEM`, `ECHO_FIND_ITEMS`, `ECHO_SUM_ITEMS`, `ECHO_REMOVE_ITEM`, `ECHO_REMEMBER_ABOUT_USER`, `ECHO_FORGET_ABOUT_USER`, `ECHO_UPDATE_ASSISTANT_NOTES`); `SavedContext` con Redis, sessione chat, segmento, embedding.
- **Dipende da**: Routines Engine, `services/saved.py`, `services/user_facts.py`, `services/phone_location.py`, Assistants, Data Model and Migrations.

### Intent Router
- **Percorso**: `backend/app/actions/availability.py`, regex `_TOOL_HINT`/`_WHATSAPP_HINT` in `routers/query.py`
- **Responsabilità**: pre-filtro a parole chiave (`might_need_tools`) e una chiamata `complete_json` (`classify_request`) che decide `Route` `memory`/`notice`/`agent`/`photo` e le app coinvolte; messaggi fissi localizzati per app non collegate o irraggiungibili.
- **Dipende da**: LLM Provider Layer (servizio intent), Action Providers (lista connessi).

### Action Providers
- **Percorso**: `backend/app/actions/provider.py`, `composio_provider.py`, `phone_provider.py`, `whatsapp_provider.py`
- **Responsabilità**: protocollo `ActionProvider`; `ComposioActionProvider` (SDK sincrono in thread, timeout 20 s, cache connessioni 60 s e schemi 600 s, max 100 tool offerti, `ActionOutcomeUnknown` sui timeout di `execute`); `PhoneActionProvider` (comando `phone_action` via Redis, attesa risultato 25 s); `WhatsAppProvider` (2 tool di lettura sul bridge); compositori `WithPhoneApps`, `WithWhatsApp`; null object `NO_APPS`.
- **Dipende da**: Composio (esterno), Device Commands, WhatsApp Bridge, Redis.

### Voice Requests
- **Percorso**: `backend/app/actions/voice.py`, `backend/app/workers/voice_requests.py`
- **Responsabilità**: wake word (`find_wake`), raccolta del comando su più segmenti (`collect_command`, pausa 3 s, finestra 15 s), verifica LLM (`is_assistant_request`), instradamento come la chat (con fotocamera), risposta nella sessione "Echo"; idempotenza `voice:done`, audit ripristinato e messaggio di errore sui fallimenti.
- **Dipende da**: Intent Router, Action Agent, Memory and RAG, Chat History, Background Worker.

### Routines Engine
- **Percorso**: `backend/app/workers/routines.py`, `services/routines.py`, `services/routine_results.py`, `services/routine_runs.py`, `models/routine.py`, `models/routine_run.py`
- **Responsabilità**: pianificazione (`validate_schedule`, `next_run`), claim ogni 60 s con `FOR UPDATE SKIP LOCKED` (batch 20), esecuzione dell'agente come utente (`owned_by`, timeout 60 s, niente conferme né tool di routine, opzionalmente come Assistant), modi `always`/`only_if`/`only_new`, registrazione `RoutineRun`, notifica `voice_update`, pulizia dopo 90 giorni.
- **Dipende da**: Action Agent, Action Providers, Device Commands, Usage and Plans.

### Assistants
- **Percorso**: `backend/app/services/assistants.py`, `models/assistant.py`, `routers/assistants.py`, `actions/assistant_tools.py`
- **Responsabilità**: profili per utente (max 10) con nome, emoji, istruzioni, note auto-aggiornate e documenti; template work/diet/sleep; `assistant_prompt` iniettato nel prompt dell'agente; chat e routine possono appartenere a un assistant.
- **Dipende da**: Action Agent, Memory and RAG (filtro `document_ids`), Data Model and Migrations.

### MCP Server
- **Percorso**: `backend/app/mcp/server.py`, `backend/app/mcp/tools.py`
- **Responsabilità**: server MCP remoto in sola lettura per app collegate; autenticazione chiave `read`, 60 chiamate/min per chiave, ContextVar `current_mcp_key` e `usage_owner`, log `mcp_calls`, 6 tool che riusano le funzioni dei router REST e restituiscono testo umano in `quoted`.
- **Dipende da**: Core Infrastructure, Memory and RAG, router `conversations`, `digest`, `entities`, `people`.

### LLM Provider Layer
- **Percorso**: `backend/app/services/llm_base.py`, `llm_openai.py`, `embedding_base.py`, `embedding_openai.py`, `stt_base.py`, `stt_openai.py`, `stt_deepgram.py`, `web_search.py`, `voice_embedding.py`
- **Responsabilità**: astrazioni `LLMService`/`EmbeddingService`/`STTService`/`WebSearchProvider`; implementazioni OpenAI Chat Completions e Responses (reasoning effort, tool, hosted web search, immagini, streaming); quattro ruoli LLM configurabili (analysis, query, intent, vision); registrazione costi per chiamata; impronte vocali ONNX locali.
- **Dipende da**: OpenAI, Deepgram, sherpa-onnx, Usage and Plans.

### Memory and RAG
- **Percorso**: `backend/app/services/memory_retrieval.py`, `memory_answers.py`, `temporal.py`, `people.py`, `saved.py`, `places.py`, `documents.py`, `user_facts.py`, `personal.py`, `about_echo.py`, `chunking.py`
- **Responsabilità**: recupero senza LLM (embedding della domanda, ricerca coseno pgvector su chunk, priorità alle persone nominate, re-ranking con feedback, entità, riassunti, Saved, luoghi, documenti), prompt RAG e risposta (anche streaming), contesto personale (nome, istruzioni, fatti).
- **Dipende da**: LLM Provider Layer, Data Model and Migrations (pgvector).

### Analysis Pipeline
- **Percorso**: `backend/app/services/analysis_pipeline.py`, `deduplication.py`, `entity_consolidation.py`, `entity_mentions.py`, `conversation_reanalysis.py`, `transcription_enhancer.py`, `speaker_detector.py`, `voice_profiles.py`, `fact_suggestions.py`, `photos.py`
- **Responsabilità**: assegnazione conversazione, estrazione entità con persone note, deduplicazione/consolidamento, chunk incrementali con embedding, rianalisi transazionale, analisi foto con modello vision.
- **Dipende da**: LLM Provider Layer, `workers/retry.py`, Data Model and Migrations.

### Background Worker
- **Percorso**: `backend/app/workers/` (`main.py`, `stt.py`, `analysis.py`, `reanalysis.py`, `photos.py`, `summaries.py`, `digest.py`, `documents.py`, `retention.py`, `saved.py`, `places.py`, `deferred.py`, `retry.py`, `dead_letter.py`, `lifecycle.py`)
- **Responsabilità**: 13 task asyncio in un processo; consumo code Redis; `retry_with_backoff` (3 tentativi, 1/4/16 s, timeout 60 s, breaker); DLQ; shutdown graduale (30 s) con requeue.
- **Dipende da**: Analysis Pipeline, Voice Requests, Routines Engine, LLM Provider Layer, Usage and Plans, Redis.

### Chat History
- **Percorso**: `backend/app/services/chat_history.py`, `models/chat_session.py`, `routers/chat_sessions.py`
- **Responsabilità**: contesto breve in Redis (`session:{user}:{session}`, 20 messaggi, TTL 30 min) e cronologia completa in `chat_sessions.messages` (JSONB, lock `FOR UPDATE`), thread unico con Echo, collegamento ad Assistant.
- **Dipende da**: Redis, PostgreSQL.

### Usage and Plans
- **Percorso**: `backend/app/services/usage.py`, `usage_report.py`, `plans.py`, `app/usage_prices.py`, `models/llm_usage.py`, `app/cli/usage.py`, `routers/plan.py`, `workers/deferred.py`
- **Responsabilità**: `usage_owner` ContextVar e `owned_by()`; upsert giornaliero per utente/kind/model (`llm_usage`); costo in USD (`cost`, `make usage`); piani free/plus/unlimited (minuti STT al mese e al giorno, ricerche web al giorno, routine); STT differito oltre il budget.
- **Dipende da**: PostgreSQL.

### Device Commands
- **Percorso**: `backend/app/services/device_commands.py`, `routers/device.py`
- **Responsabilità**: coda per utente di comandi con scadenza (`take_photo`, `phone_action`, `get_location`, `voice_update`, `person_brief`) prelevata dall'app con long poll; marker di consegna per distinguere "mai ricevuto" da "esito sconosciuto".
- **Dipende da**: Redis, Mobile App.

### WhatsApp Bridge
- **Percorso**: `whatsapp/src/` (`main.js`, `server.js`, `sessions.js`, `store.js`, `extract.js`), client `backend/app/services/whatsapp_bridge.py`, `routers/whatsapp.py`
- **Responsabilità**: un dispositivo collegato per utente via Baileys, sola lettura, chat private in RAM 7 giorni, API HTTP interna con token condiviso.
- **Dipende da**: WhatsApp (non ufficiale), volume `whatsapp_data` per le chiavi.

### Data Model and Migrations
- **Percorso**: `backend/app/models/` (30 modelli), `backend/alembic/versions/` (30 migrazioni), `docs/schema.sql`
- **Responsabilità**: schema PostgreSQL con pgvector (`Vector(1536)` su chunk, entità, saved, document chunk; `Vector(256)` su impronte vocali); tabelle chiave per l'intent: `users`, `api_keys` (scope), `chat_sessions`, `assistants`, `routines`, `routine_runs`, `pending_actions`, `action_log`, `llm_usage`, `mcp_calls`.
- **Dipende da**: PostgreSQL 16 + pgvector.

## Componenti esterni al backend

### Mobile App
- **Percorso**: `mobile/` (Flutter; `lib/services/{api,app,chat,device,memory,onboarding,phone}`, `lib/screens`, `lib/widgets`, `lib/models`)
- **Responsabilità**: relay BLE del wearable, UI, long poll dei comandi, esecuzione di Promemoria/Calendario, notifiche locali, TTS delle risposte, aggiornamento firmware via BLE.
- **Dipende da**: API Server, Wearable Firmware.

### Wearable Firmware
- **Percorso**: `firmware/src/` (header + `main.ino`), `firmware/test/`
- **Responsabilità**: VAD, buffer PSRAM e microSD cifrata, ADPCM, protocollo BLE con ACK, fotocamera, pulsante, OTA firmata ECDSA P-256.
- **Dipende da**: Mobile App (BLE).

### Simulator
- **Percorso**: `simulator/`
- **Responsabilità**: simula il dispositivo inviando segmenti ADPCM all'API.
- **Dipende da**: API Server.

### Evals
- **Percorso**: `backend/evals/`
- **Responsabilità**: valutazioni con chiamate reali (compatibilità, estrazione, instradamento, risposte, scelta del primo tool) e confronto STT.
- **Dipende da**: Action Agent, Intent Router, LLM Provider Layer.

### Deployment Tooling
- **Percorso**: `docker-compose.yml`, `docker-compose-infra.yml`, `Makefile`, `scripts/`, `backend/Dockerfile`, `backend/entrypoint.sh`, `.github/workflows/ci.yml`
- **Responsabilità**: stack Compose a host singolo (api, worker, postgres, redis, whatsapp, tunnel), deploy idempotente, rilascio firmware firmato, CI.
- **Dipende da**: tutti i componenti eseguibili.
