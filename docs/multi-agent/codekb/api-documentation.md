# API Documentation — Echo

## Autenticazione e limiti (trasversali)

| Meccanismo | Dove | Regole |
|---|---|---|
| `X-API-Key` (scope `full`) | `core/auth.get_current_api_key` / `get_current_user_id` | Hash SHA-256 in `api_keys.key_hash`; chiave di esempio `my-secret-key` sempre rifiutata; una chiave `read` sulla REST → 403; 10 tentativi falliti in 15 min per IP (`auth_fail:<ip>`, IP da `CF-Connecting-IP`) → 429; chiavi revocate ricordate 24 h. Imposta `usage_owner` e `request.state.rate_limit_owner` |
| `Authorization: Bearer` (scope `read`) | `core/auth.authenticate_connected_app` | Solo su `/mcp`; contatore fallimenti separato (`mcp_auth_fail:<ip>`) |
| `X-Admin-Token` | `core/auth.require_operator` | `/api/admin/*`; senza `ADMIN_TOKEN` gli endpoint rispondono 404 |
| `Bearer METRICS_TOKEN` o API key | `main._authorize_metrics` | `/metrics` |
| Rate limit | `core/rate_limit.limiter` (slowapi, memoria di processo) | Chiave `user:<id>` dopo l'autenticazione, altrimenti hash della chiave o IP. `POST /query` e `/query/stream` 20/min, `POST /segments` 60/min, `POST /photos` e `PUT /photos/{id}/image` 30/min, `POST /photos/{id}/ask` 20/min; MCP 60 chiamate/min per chiave (Redis) |
| Correlation ID | `main.correlation_id_middleware` | Header di risposta `X-Correlation-ID` (8 caratteri) |

## REST API (prefisso `/api`)

| Router (file) | Endpoint principali |
|---|---|
| auth (`routers/auth.py`) | `POST /auth/login`, `POST /auth/register`, `GET/PATCH /auth/me`, `POST /auth/logout`, `GET /auth/devices`, `POST /auth/connected-apps` (chiave `read`, max 10), `DELETE /auth/devices/{id}` |
| segments (`routers/segments.py`) | `POST /segments` (multipart ADPCM ≤5 MB, header `X-Recorded-At`, `X-Duration-Ms`…; idempotente su hash audio + `recorded_at`; `lpush queue:stt`), `GET /segments/recent`, `PATCH /segments/{id}/transcription` (→ `queue:reanalysis`) |
| query (`routers/query.py`) | `POST /query`, `POST /query/stream` (SSE `token`/`done`/`error`) — corpo `QueryRequest{question, top_k, date_from, date_to, session_id, assistant_id, client_request_id}`; risposta `QueryResponse{answer, sources, session_id, date_filter, pending_action, web_sources, saved}`; 409 "Still working on it" durante un retry |
| feedback (`routers/feedback.py`) | `POST /query/feedback` |
| chat_sessions | `GET /chat-sessions`, `GET /chat-sessions/thread`, `GET/DELETE /chat-sessions/{id}` |
| actions (`routers/actions.py`) | `GET /actions/toolkits?query=`, `POST /actions/toolkits/{slug}/connect`, `DELETE /actions/toolkits/{slug}`, `GET /actions/pending`, `POST /actions/pending/{id}/confirm` (404/409/410; `status`: `executed`\|`failed`\|`unknown`), `POST /actions/pending/{id}/cancel`, `GET /actions/log`, `GET /actions/voice-updates?since=`, `GET /actions/voice-working`. Senza `COMPOSIO_API_KEY` → 503 |
| assistants | `GET /assistants/templates`, `GET/POST /assistants`, `PATCH/DELETE /assistants/{id}` (max 10; nome 40, istruzioni 2.000, note 3.000, `document_ids`) |
| routines, routine_runs | `GET /routines`, `PATCH/DELETE /routines/{id}`; `GET /routine-runs`, `POST /routine-runs/{id}/ask` (creazione solo via agente) |
| conversations | `GET /conversations`, `GET /conversations/{id}`, `POST /conversations/{id}/translate`, `DELETE /conversations/{id}` |
| entities, people, search | `GET /entities`, `/entities/stats`, `/entities/people`, `/entities/tasks`, `PATCH/DELETE /entities/{id}`, `POST /entities/{id}/merge`, `POST /entities/deduplicate`; `GET /people`, `GET /people/{id}`; `GET /search?q=` |
| digest | `GET /digest`, `GET/POST /digest/{date}`, `GET /digest/weekly`, `POST /digest/weekly/{monday}` |
| facts, documents | `GET/POST /facts`, `PATCH/DELETE /facts/{id}`, `POST /facts/{id}/keep`; `GET/POST /documents`, `GET/DELETE /documents/{id}` |
| saved, places | `GET /saved`, `/saved/lists`, `/saved/lists/{id}`, `/saved/items/{id}` (+ PATCH, PUT place, DELETE); `POST/GET/DELETE /places/visits`, `DELETE /places/days/{day}` |
| photos | `POST /photos`, `GET /photos/{id}`, `PUT /photos/{id}/image`, `POST /photos/{id}/failure`, `POST /photos/{id}/ask`, `GET /photos/{id}/image` |
| device | `GET /device/commands?wait=0..25` (long poll), `POST /device/commands/{id}/result`, `PUT /device/phone-apps` |
| voices | `GET /voice-profiles`, `POST /voice-profiles/self/enroll`, `DELETE /voice-profiles/{id}`, `POST /segments/{id}/voice`, `POST /segments/{id}/voice/reject` |
| notifications | `GET/POST /notifications/upcoming`, `POST /notifications/coming-up` |
| plan, whatsapp, firmware, export | `GET /plan`; `GET /whatsapp`, `POST /whatsapp/link`, `DELETE /whatsapp`; `GET /firmware/latest`, `GET /firmware/{version}/image`; `GET /export` |
| admin | `GET /admin/dead-letter`, `POST /admin/dead-letter/retry` |
| sistema (`main.py`) | `GET /health` (Postgres, Redis, lunghezza code, stato `openai_breaker`), `GET /api/stats`, `GET /metrics` |

## MCP server (`/mcp`)

Streamable HTTP, `stateless_http=True`, `json_response=True`, FastMCP `"Echo"` (`mcp/server.py`). Un `StreamableHTTPSessionManager` per richiesta. Ogni chiamata è registrata in `mcp_calls` (tool + riassunto ≤200 caratteri) e conteggiata per l'utente.

| Tool | Firma | Ritorno |
|---|---|---|
| `search_memory` | `(query, date_from?, date_to?, limit=5)` | `{quoted, sources[{conversation_id, title, started_at, excerpt}]}` — senza luoghi né documenti |
| `get_conversation` | `(conversation_id)` | titolo, orari, riassunto, righe con speaker, foto, task, eventi |
| `find_person` | `(name)` | fino a 5 persone con ruolo, cosa si sa, ultimo incontro, task aperti, conversazioni |
| `list_tasks` | `(status="open", due_before?)` | task con frase d'origine |
| `get_day` | `(date)` | digest e conversazioni del giorno |
| `get_week` | `(week_start)` | riassunto settimanale |

Il testo prodotto da persone è sempre dentro `{"quoted": …}`; gli errori sono `ToolError`.

## Contratti interni (Python)

### `LLMService` (`services/llm_base.py`)

```python
class LLMService(ABC):
    can_search = False
    async def complete(messages, temperature=0.3) -> LLMResponse
    async def stream(messages, temperature=0.3) -> AsyncIterator[str]
    async def complete_json(messages, temperature=0.1) -> dict
    async def complete_with_tools(messages, tools, temperature=0.2) -> LLMResponse
```
`LLMMessage(role, content, tool_calls, tool_call_id, name, images)`, `LLMToolCall(id, name, arguments)`, `LLMResponse(content, model, usage_tokens, input_tokens, output_tokens, cached_tokens, tool_calls, citations)`. Implementazioni: `OpenAILLMService` (Chat Completions), `OpenAIResponsesLLMService` (Responses API, `can_search=True`, `hosted_tools`). Factory per ruolo: `get_llm_analysis_service`, `get_llm_query_service`, `get_llm_intent_service`, `get_llm_vision_service`.

### `ActionProvider` (`actions/provider.py`, `Protocol`)

```python
async def list_toolkits(user_id, query=None) -> list[Toolkit]
async def connected_toolkits(user_id) -> list[str]
async def connect_link(user_id, toolkit, callback_url) -> str
async def disconnect(user_id, toolkit) -> None
async def tools_for(user_id, toolkits) -> list[dict]   # schemi OpenAI, function.name = slug
async def execute(user_id, tool, arguments) -> ToolResult
```
`ToolResult(ok, data, error, unknown)`; eccezioni `ActionProviderError`, `ActionOutcomeUnknown` (timeout dopo l'invio), `AccountNotConnectedError`. Implementazioni: `ComposioActionProvider`, `PhoneActionProvider`, `WhatsAppProvider`, composti da `WithPhoneApps`, `WithWhatsApp`; null object `NO_APPS`.

### Agente (`actions/agent.py`)

```python
async def run_action_agent(db, user_id, request, history, *, session_id, source,
    provider, llm, max_steps=6, connected_toolkits=None, routine_tools=True,
    allow_confirm=True, saved=None, language=None, assistant=None) -> AgentOutcome
```
`AgentOutcome(answer, pending_action, executed_tools, web_sources, saved)`. Tool sempre offerti: `search_memory`; con `routine_tools`: `ECHO_CREATE_ROUTINE`, `ECHO_LIST_ROUTINES`, `ECHO_DELETE_ROUTINE`, `ECHO_CREATE_TASK`, `ECHO_SAVE_ITEM`, `ECHO_UPDATE_ITEM`, `ECHO_FIND_ITEMS`, `ECHO_SUM_ITEMS`, `ECHO_REMOVE_ITEM`, `ECHO_REMEMBER_ABOUT_USER`, `ECHO_FORGET_ABOUT_USER`; con `assistant`: `ECHO_UPDATE_ASSISTANT_NOTES`. Risultati dei tool troncati a 12.000 caratteri.

### Instradatore (`actions/availability.py`)

`route_request(llm, request, history, connected, camera=False) -> Route(kind: "memory"|"notice"|"agent"|"photo", notice, apps, save)`; una chiamata `complete_json` che restituisce `{camera?, routine, todo, saved, needs_apps, apps}`; errori → memoria.

### Altri contratti

- `EmbeddingService.embed / embed_batch` (1536 dimensioni, `text-embedding-3-small`).
- `STTService.transcribe(audio_data, language, prompt, keyterms, also) -> STTResult`.
- `WebSearchProvider.hosted_tool()`; `search_tool_for(llm, user_id)` applica il limite giornaliero del piano.
- `retrieve_memory_context(db, user_id, question, top_k, date_range, embedding_service, include_places, include_documents, document_ids) -> MemoryContext(context, sources, date_range)`.
- `record_usage(kind, model, *, input_units, output_units, cached_units)`.
- `push_device_command(redis, user_id, command, ttl_s)` / `take_device_commands`.

## Code Redis e chiavi (contratti asincroni)

| Chiave | Produttore | Consumatore | Payload |
|---|---|---|---|
| `queue:stt` | `routers/segments.py` | `workers/stt.process_stt` | segment id |
| `queue:stt:deferred` | `workers/deferred.py`, `workers/stt.py` | `workers/stt.process_stt` (priorità bassa) | segment id |
| `queue:analysis` | `workers/stt.py` | `workers/analysis.process_analysis` | segment id |
| `queue:reanalysis` | `routers/segments.py` | `workers/reanalysis.process_reanalysis` | JSON `ReanalysisPayload` |
| `queue:voice` | `workers/stt._enqueue_voice_request` | `workers/voice_requests.process_voice_queue` | segment id |
| `queue:photos` | `routers/photos.py` | `workers/photos.process_photos` | photo id |
| `queue:dead-letter` | `workers/dead_letter.py` | `routers/admin.py` | JSON `{segment_id\|conversation_id, step, error, attempts, failed_at}` |
| `device:commands:{user_id}` | foto, telefono, routine, person brief | `GET /api/device/commands` | JSON con `type`, `expires_at` |
| `phone:result:{command_id}` | `POST /device/commands/{id}/result` | `PhoneActionProvider.execute` (`blpop` 25 s) | JSON risultato |
| `session:{user_id}:{session_id}` | `chat_history.save_session_history` | `load_thread_history` | ultimi 20 messaggi, TTL 30 min |
| `query:req:{user_id}:{client_request_id}` | `routers/query._claim_request` | idem | `processing` o risposta, TTL 10 min |
| `voice:done:{segment_id}`, `voice:working:{user_id}` | `workers/voice_requests.py` | idem, `/actions/voice-working` | marker |
| `whatsapp:linked:{user_id}` | `whatsapp_provider.whatsapp_linked` | idem | `1`/`0`, TTL 60 s |

## API interna del bridge WhatsApp (`whatsapp/src/server.js`)

Header `X-Bridge-Token` (confronto `timingSafeEqual`). `GET /users/:id/status`, `POST /users/:id/link {phone}` → `{code}`, `DELETE /users/:id`, `GET /users/:id/chats?limit=`, `GET /users/:id/messages?chat=&name=&since=&limit=`. Client Python: `services/whatsapp_bridge.WhatsAppBridge` (httpx, timeout 3–30 s, `BridgeError`).
