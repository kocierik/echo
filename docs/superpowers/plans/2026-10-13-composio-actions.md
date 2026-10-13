# Echo Actions via Composio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user ask Echo — in the Ask chat or by voice ("Echo, …") — to read/summarize and act on Gmail, Google Calendar, Slack, Telegram (bot), Todoist and Notion through Composio, with in-app confirmation for sending/modifying/deleting, and remove the old automatic integrations and Rules.

**Architecture:** A provider-agnostic `ActionProvider` adapter (Composio implementation + test fake) feeds tools to an OpenAI tool-calling agent loop that also has a `search_memory` tool. Chat requests reach the agent from `POST /api/query` when the cheap pre-check and the intent check say tools are needed; voice requests are detected after STT, assembled across segments by a worker loop and answered into a "Voice requests" chat session. Confirm-tier tool calls become pending actions confirmed from the app; every executed call is audited.

**Tech Stack:** Python 3.11, FastAPI, SQLAlchemy async, Alembic, Redis worker, OpenAI Chat Completions tool calling, Composio Python SDK (`composio`, `composio_openai`); Flutter (Dart 3), `flutter_local_notifications`.

**Spec:** `docs/superpowers/specs/2026-10-13-composio-actions-design.md`

## Global Constraints

- Actions run **only** on an explicit request: chat, or voice addressed to Echo by name. No action from overheard speech.
- Tiers: `read` and `create` run immediately; `confirm` (send to others, modify, delete) needs in-app confirmation. **Unknown tools default to `confirm`.**
- Pending actions expire after **30 minutes** and can be confirmed **once**.
- Never send audio or full transcripts to Composio; send only tool arguments.
- Raw tool results are never persisted; chat stores question + final answer; the audit log stores a short argument summary, outcome and error only.
- Voice wake spellings: "Echo", "Eco", "Hey Echo", "Ehi Echo" (case-insensitive, whole word, at or near the utterance start).
- Voice command window: text from the name onward plus following segments until a pause of **3 s** (`silence_before_ms >= 3000`) or **15 s** after the wake segment start.
- Voice requests go to one chat session per user titled **"Voice requests"** (`kind = "voice"`), pinned at the top of Ask history.
- Notification delivery is "at the next occasion": the app checks for voice answers on every segment upload and on app resume. No APNs.
- Answers are in the language of the request; app texts in English.
- Calendar defaults kept in the agent prompt: default duration **1 hour**, timezone `settings.user_timezone`, a new time keeps day and duration, find events by title/day when no id is known.
- Initial toolkits (Composio slugs): `gmail`, `googlecalendar`, `slack`, `telegram`, `todoist`, `notion`.
- One new setting: `COMPOSIO_API_KEY`. Settings removed: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REDIRECT_URI`, `OAUTH_STATE_SECRET`, `DEFAULT_EVENT_DURATION_MINUTES`.
- All tests use the fake provider and fake LLM; no network. Backend unit tests run with `pytest --noconftest` (no DB) wherever possible.
- Lint: `ruff check app/ tests/` must stay clean (line length 100).

## Review Focus

1. **Composio unreachable or account disconnected mid-request** — the user gets an explicit "couldn't reach Gmail / Gmail isn't connected" answer; nothing is logged as success. Test in Task 7.
2. **Confirm tapped twice, or after expiry** — the second confirm returns 409 and the tool runs exactly once; expired returns 410. Test in Task 5.
3. **Wake-name false positives** — "ecografia", "l'eco della stanza", "ho comprato un Echo" do not start a request. Test in Task 10.
4. **Huge tool output** (e.g. 100 emails) — tool results passed to the LLM are truncated to 12 000 characters with a "[truncated]" marker. Test in Task 7.
5. **Two confirm-tier calls in one model turn** (e.g. "send this to Ada and Marco") — the first becomes a pending action, the loop stops, the second is not executed. Test in Task 7.

---

## File Structure

Backend (new): `app/actions/` — `provider.py` (interface + types), `policy.py` (tiers), `composio_provider.py` (real adapter), `audit.py`, `pending.py`, `agent.py`, `voice.py`; `app/services/memory_retrieval.py` (extracted RAG retrieval); `app/models/pending_action.py`, `app/models/action_log.py`; `app/routers/actions.py`; `app/workers/voice_requests.py`; migrations `007_actions.py`, `008_drop_rules_integrations.py`; `tests/fakes/action_provider.py`.
Backend (modified): `app/services/llm_base.py`, `app/services/llm_openai.py`, `app/routers/query.py`, `app/routers/chat_sessions.py`, `app/models/chat_session.py`, `app/workers/main.py`, `app/services/analysis_pipeline.py`, `app/core/config.py`, `app/main.py`.
Backend (removed in Task 11): `app/integrations/`, `app/services/rules_engine.py`, `app/services/calendar_service.py`, `app/services/chat_actions.py`, `app/routers/rules.py`, `app/routers/integrations.py`, `app/routers/oauth.py`, `app/core/oauth_state.py`, `app/models/rule.py`, `app/models/integration.py` and their tests.
Mobile (new): `lib/models/action_models.dart`, `lib/widgets/action_card.dart`, `lib/screens/action_log_screen.dart`, `lib/services/voice_updates_service.dart`.
Mobile (modified): `lib/services/api_service.dart`, `lib/models/chat_message.dart`, `lib/models/chat_session.dart`, `lib/services/chat_controller.dart`, `lib/screens/chat_screen.dart`, `lib/screens/chat_history_screen.dart`, `lib/screens/integrations_screen.dart`, `lib/screens/settings/automations_settings_screen.dart`, `lib/services/notification_service.dart`, `lib/services/app_lifecycle_coordinator.dart`. Removed: `lib/screens/rules_screen.dart`.

---

### Task 1: LLM tool calling

**Files:**
- Modify: `backend/app/services/llm_base.py`, `backend/app/services/llm_openai.py`
- Test: `backend/tests/test_llm_tool_calling.py`

**Interfaces:**
- Produces:
  - `LLMToolCall(id: str, name: str, arguments: dict)` dataclass.
  - `LLMMessage` gains optional `tool_calls: list[LLMToolCall] | None = None`, `tool_call_id: str | None = None`, `name: str | None = None`; `role` may be `"tool"`.
  - `LLMResponse` gains `tool_calls: list[LLMToolCall] = field(default_factory=list)`.
  - `LLMService.complete_with_tools(messages: list[LLMMessage], tools: list[dict], temperature: float = 0.2) -> LLMResponse` (abstract); `OpenAILLMService` implements it with `tools=` and `tool_choice="auto"`, parsing `arguments` JSON (invalid JSON → `{}`).

- [ ] **Step 1: Write the failing tests** — with a fake `client.chat.completions.create` capturing kwargs:
  - `test_tool_calls_are_parsed`: a response with one tool call `{"id": "c1", "function": {"name": "GMAIL_FETCH_EMAILS", "arguments": "{\"max_results\": 5}"}}` → `response.tool_calls == [LLMToolCall("c1", "GMAIL_FETCH_EMAILS", {"max_results": 5})]`.
  - `test_tools_and_messages_are_sent_in_openai_format`: an assistant message with `tool_calls` and a `role="tool"` message with `tool_call_id="c1"` serialize to OpenAI's shapes; `kwargs["tools"]` is passed through.
  - `test_invalid_tool_arguments_become_empty_dict`.
- [ ] **Step 2: Run** `pytest tests/test_llm_tool_calling.py -q --noconftest` — Expected: FAIL (`LLMToolCall` not defined).
- [ ] **Step 3: Implement** the types and `complete_with_tools`; keep `complete`/`complete_json` unchanged; test doubles in `tests/mocks.py` gain a `complete_with_tools` that returns queued responses.
- [ ] **Step 4: Run** the test file and `pytest tests -q --noconftest` — Expected: PASS (only the known `test_transcription_edit_is_registered` failure and DB fixture errors remain).
- [ ] **Step 5: Commit** `feat(llm): OpenAI tool calling support`.

### Task 2: Action provider interface, tool policy and fake

**Files:**
- Create: `backend/app/actions/__init__.py`, `backend/app/actions/provider.py`, `backend/app/actions/policy.py`, `backend/tests/fakes/__init__.py`, `backend/tests/fakes/action_provider.py`
- Test: `backend/tests/test_action_policy.py`

**Interfaces:**
- Produces (`provider.py`):
  - `Toolkit(slug: str, name: str, description: str, connected: bool)`.
  - `ToolResult(ok: bool, data: dict | list | str | None = None, error: str | None = None)`.
  - `ActionProviderError(Exception)`; `AccountNotConnectedError(ActionProviderError)` with attribute `toolkit: str`.
  - `class ActionProvider(Protocol)`: `async list_toolkits(user_id: str, query: str | None = None) -> list[Toolkit]`; `async connect_link(user_id: str, toolkit: str, callback_url: str | None) -> str`; `async disconnect(user_id: str, toolkit: str) -> None`; `async tools_for(user_id: str, toolkits: list[str]) -> list[dict]` (OpenAI tool schemas, `function.name` = tool slug); `async execute(user_id: str, tool: str, arguments: dict) -> ToolResult`.
  - `INITIAL_TOOLKITS = ("gmail", "googlecalendar", "slack", "telegram", "todoist", "notion")`.
- Produces (`policy.py`): `class ToolTier(StrEnum): READ, CREATE, CONFIRM`; `classify_tool(slug: str) -> ToolTier`; `toolkit_of(slug: str) -> str` (prefix before the first `_`, lowercased).
- Produces (`tests/fakes/action_provider.py`): `FakeActionProvider` implementing the protocol, configured with `connected: set[str]`, `tools: dict[str, dict]`, `results: dict[str, ToolResult | Exception]`; records `executed: list[tuple[str, dict]]`.

`classify_tool` rule order: a confirm keyword anywhere in the slug (`SEND`, `DELETE`, `REMOVE`, `UPDATE`, `PATCH`, `MOVE`, `REPLY`, `FORWARD`, `POST`, `TRASH`, `ARCHIVE`, `MODIFY`, `COMPLETE`, `CLOSE`) → CONFIRM; slug in `CREATE_TOOLS` (explicit set; Task 3 fills real slugs) → CREATE; a read keyword (`LIST`, `GET`, `FETCH`, `SEARCH`, `FIND`, `READ`) → READ; otherwise CONFIRM.

- [ ] **Step 1: Write the failing tests**: `GMAIL_SEND_EMAIL`, `GOOGLECALENDAR_DELETE_EVENT`, `GOOGLECALENDAR_UPDATE_EVENT`, `SLACK_SEND_MESSAGE` → CONFIRM; `GMAIL_FETCH_EMAILS`, `GOOGLECALENDAR_EVENTS_LIST`, `SLACK_FETCH_CONVERSATION_HISTORY` → READ; `GMAIL_CREATE_EMAIL_DRAFT`, `GOOGLECALENDAR_CREATE_EVENT`, `TODOIST_CREATE_TASK` → CREATE; `SOMEAPP_DO_MAGIC` → CONFIRM; `GMAIL_FETCH_AND_DELETE` → CONFIRM; `toolkit_of("GOOGLECALENDAR_CREATE_EVENT") == "googlecalendar"`.
- [ ] **Step 2: Run** — Expected: FAIL (module missing).
- [ ] **Step 3: Implement** the three files; `CREATE_TOOLS` initially `{"GMAIL_CREATE_EMAIL_DRAFT", "GOOGLECALENDAR_CREATE_EVENT", "GOOGLECALENDAR_QUICK_ADD", "TODOIST_CREATE_TASK", "NOTION_CREATE_NOTION_PAGE"}`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(actions): provider interface, tool tiers and test fake`.

### Task 3: Composio provider

**Files:**
- Create: `backend/app/actions/composio_provider.py`
- Modify: `backend/pyproject.toml` (add `composio`, `composio_openai`, pinned to the versions installed), `backend/app/core/config.py` (`composio_api_key: str = ""`), `.env.example`, `backend/app/actions/policy.py` (real `CREATE_TOOLS` slugs)
- Test: `backend/tests/test_composio_provider.py`

**Interfaces:**
- Consumes: Task 2 types.
- Produces: `ComposioActionProvider(client=None)` implementing `ActionProvider`; `get_action_provider() -> ActionProvider` (singleton; raises `ActionProviderError("Composio is not configured")` when `settings.composio_api_key` is empty).

- [ ] **Step 1: Verify the SDK** in a scratch venv: `pip install composio composio_openai`, then inspect `help()` of `Composio().connected_accounts.link`, `.list`, `.delete`, `tools.get`, `tools.execute`, and how to list toolkits. Record the exact signatures and result shapes (status `ACTIVE`, `redirect_url`, execute result `successful/data/error`) as a module docstring. Fill `CREATE_TOOLS` with the real slugs of the create tools of the six initial toolkits. If the docs/SDK show managed auth needs an auth-config id per toolkit, look it up with the SDK; only if impossible, add `COMPOSIO_AUTH_CONFIG_IDS` (JSON toolkit→id) to settings and `.env.example`.
- [ ] **Step 2: Write the failing tests** against a stub SDK client object (no network):
  - `test_execute_maps_success_and_failure`: SDK result successful → `ToolResult(ok=True, data=...)`; unsuccessful → `ok=False, error=...`; SDK exception → `ActionProviderError`.
  - `test_execute_without_connected_account_raises_account_not_connected`.
  - `test_list_toolkits_marks_connected_ones` and returns the six initial toolkits first.
  - `test_connect_link_returns_redirect_url`; `test_disconnect_deletes_the_active_account`.
  - `test_missing_api_key_is_a_clear_error`.
- [ ] **Step 3: Run** — Expected: FAIL.
- [ ] **Step 4: Implement**; every SDK call runs via `asyncio.to_thread` with a 20 s timeout; Composio `user_id` = `str(echo_user_id)`.
- [ ] **Step 5: Run** — Expected: PASS; `ruff` clean.
- [ ] **Step 6: Commit** `feat(actions): Composio provider`.

### Task 4: Data model and migration 007

**Files:**
- Create: `backend/app/models/pending_action.py`, `backend/app/models/action_log.py`, `backend/alembic/versions/007_actions.py`
- Modify: `backend/app/models/__init__.py`, `backend/app/models/chat_session.py` (`kind: Mapped[str]`, default `"chat"`), `docs/schema.sql` (append the same tables/column)
- Test: `backend/tests/test_actions_schema.py`

**Interfaces:**
- Produces:
  - `PendingAction`: `id`, `user_id`, `session_id` (UUID), `source` (`"chat" | "voice"`), `tool` (str), `arguments` (JSONB), `summary` (Text), `status` (`pending|executed|failed|cancelled|expired`), `created_at`, `expires_at`, `resolved_at`.
  - `ActionLog`: `id`, `user_id`, `source`, `toolkit`, `tool`, `arguments_summary` (Text), `outcome` (`ok|error`), `error` (Text | None), `created_at`; index `(user_id, created_at)`.
  - `ChatSession.kind`: `"chat"` or `"voice"`.

- [ ] **Step 1: Write the failing tests** (metadata only, no DB): the tables and columns exist on `Base.metadata`; `ChatSession.kind` default `"chat"`; migration `007` has `down_revision == "006"` and is idempotent (uses the inspector like 006).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(actions): pending actions, action log, voice chat sessions`.

### Task 5: Audit and pending actions

**Files:**
- Create: `backend/app/actions/audit.py`, `backend/app/actions/pending.py`
- Test: `backend/tests/test_pending_actions.py`, `backend/tests/test_action_audit.py`

**Interfaces:**
- Produces (`audit.py`): `summarize_arguments(arguments: dict) -> str` (each value as text cut to 80 chars, keys `body`, `message`, `text`, `content` replaced by their length "(N chars)", whole summary ≤ 300 chars); `async log_action(db, user_id, source: str, tool: str, arguments: dict, result: ToolResult) -> ActionLog`.
- Produces (`pending.py`): `PENDING_TTL = timedelta(minutes=30)`; `async create_pending_action(db, user_id, session_id, source, tool, arguments, summary) -> PendingAction`; `async confirm_pending_action(db, user_id, action_id, provider, now=None) -> ToolResult` raising `PendingActionNotFound` (404), `PendingActionResolved` (409), `PendingActionExpired` (410); `async cancel_pending_action(db, user_id, action_id) -> PendingAction`. Confirm locks the row (`with_for_update`), executes, logs via `log_action`, sets status `executed`/`failed`.

- [ ] **Step 1: Write the failing tests** (fake session + `FakeActionProvider`):
  - `test_confirm_executes_the_stored_arguments_once` — second confirm raises `PendingActionResolved`, `provider.executed` has one entry. *(Review Focus 2)*
  - `test_confirm_after_30_minutes_is_expired` — status becomes `expired`, nothing executed. *(Review Focus 2)*
  - `test_cancel_never_executes`; `test_other_users_action_is_not_found`.
  - `test_failed_execution_is_logged_as_error_and_marked_failed`.
  - `test_argument_summary_hides_bodies`: `{"to": "ada@x.it", "body": "x"*500}` → contains `ada@x.it` and `(500 chars)`, not the body.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(actions): audited, single-use pending actions`.

### Task 6: Memory retrieval as a reusable function

**Files:**
- Create: `backend/app/services/memory_retrieval.py`
- Modify: `backend/app/routers/query.py` (use it; no behaviour change)
- Test: `backend/tests/test_memory_retrieval.py`

**Interfaces:**
- Produces: `MemoryContext(context: str, sources: list[dict], date_range: DateRange | None)`; `async retrieve_memory_context(db, user_id, question: str, top_k: int = 5, date_range: DateRange | None = None) -> MemoryContext` — the current steps 2–6 of `query_memory` (embed, chunk search with overlap filter, feedback re-ranking, entities, summaries, context assembly). `context == ""` means nothing found.

- [ ] **Step 1: Write the failing test** with patched embedding service and a fake DB returning one chunk: the returned context contains the chunk text and the "Structured knowledge" section when entities exist; empty memory → `context == ""`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Move** the code; `query_memory` calls `retrieve_memory_context` and keeps its responses identical.
- [ ] **Step 4: Run** the new test plus `tests/test_query_date_filters.py tests/test_language.py tests/test_chat_history_persistence.py` — PASS.
- [ ] **Step 5: Commit** `refactor(query): extract memory retrieval`.

### Task 7: Agent loop

**Files:**
- Create: `backend/app/actions/agent.py`
- Test: `backend/tests/test_action_agent.py`

**Interfaces:**
- Consumes: Task 1 (`complete_with_tools`, `LLMToolCall`), Task 2 (provider, `classify_tool`, `toolkit_of`), Task 5 (`create_pending_action`, `log_action`), Task 6 (`retrieve_memory_context`).
- Produces: `AgentOutcome(answer: str, pending_action: PendingAction | None, executed_tools: list[str])`; `async run_action_agent(db, user_id, request: str, history: list[dict], *, session_id, source: str, provider: ActionProvider, llm: LLMService, max_steps: int = 6) -> AgentOutcome`; `SEARCH_MEMORY_TOOL` schema (name `search_memory`, argument `query: str`); `MAX_TOOL_RESULT_CHARS = 12_000`.

Loop: system prompt (English; "answer in the language of the user's request"; today's date and `settings.user_timezone`; calendar rules from Global Constraints; never claim an action happened unless its tool result says so) + history + request; tools = `search_memory` + `provider.tools_for(user, connected initial-or-other toolkits)`. Per model turn: execute READ/CREATE calls (log each), feed results back (JSON, truncated); the first CONFIRM call → `create_pending_action` with `summary = f"{tool}: {summarize_arguments(arguments)}"`, stop, and answer with the summary and "Confirm in the app to proceed." (localized by `detect_language`). Stop after `max_steps` with a clear message.

- [ ] **Step 1: Write the failing tests** (fake LLM with scripted turns, `FakeActionProvider`):
  - `test_read_tool_result_is_summarized` — `GMAIL_FETCH_EMAILS` executed once, final answer from the second turn, one audit row.
  - `test_confirm_tool_creates_pending_action_and_is_not_executed`.
  - `test_second_confirm_call_in_the_same_turn_is_dropped` *(Review Focus 5)*.
  - `test_tool_result_is_truncated_for_the_model` — a 50 000-char result reaches the LLM as ≤ 12 000 chars ending with `[truncated]` *(Review Focus 4)*.
  - `test_disconnected_account_gives_an_explicit_answer` and `test_provider_error_is_reported_not_claimed` — answer names the toolkit; audit outcome `error` *(Review Focus 1)*.
  - `test_search_memory_tool_uses_memory_retrieval`.
  - `test_step_limit_stops_the_loop`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(actions): tool-calling agent with confirmations`.

### Task 8: Chat uses the agent

**Files:**
- Modify: `backend/app/routers/query.py`, `backend/app/routers/chat_sessions.py`
- Test: `backend/tests/test_query_actions.py`

**Interfaces:**
- Consumes: Task 7 `run_action_agent`; `get_action_provider()`.
- Produces:
  - `might_need_tools(question: str, history: list[dict]) -> bool` (moved here from `chat_actions.might_be_calendar_action`, keywords extended with mail/email/posta/gmail, slack, telegram, messag-, todoist, task, notion, nota/note, inbox).
  - `async needs_tools(llm, question, history, connected: list[str]) -> bool` (JSON intent check; `False` when no toolkit is connected).
  - `QueryResponse.pending_action: PendingActionOut | None` with `PendingActionOut(id: uuid.UUID, summary: str, status: str, expires_at: datetime)`.
  - Persisted assistant messages may carry `"pending_action": {"id", "summary", "status"}`; `ChatMessage` schema in `chat_sessions.py` gains `pending_action: dict | None`; `ChatSessionSummary` gains `kind: str`; list ordering puts `kind == "voice"` first.

- [ ] **Step 1: Write the failing tests**: memory question with no hint words never calls the provider; "riassumimi le ultime mail" with Gmail connected goes to the agent and returns its answer; a confirm outcome returns `pending_action` and stores it in the session message; with no connected toolkit the RAG path runs; voice sessions list first.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement**, replacing the `detect_and_execute_action` call. **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(chat): route tool requests to the action agent`.

### Task 9: Actions API

**Files:**
- Create: `backend/app/routers/actions.py`; Modify: `backend/app/main.py` (include router)
- Test: `backend/tests/test_actions_router.py`

**Interfaces:**
- Produces (all under `/api/actions`, API key required):
  - `GET /toolkits?query=` → `list[ToolkitOut(slug, name, description, connected)]`.
  - `POST /toolkits/{slug}/connect` → `{"url": str}`; `DELETE /toolkits/{slug}` → 204.
  - `POST /pending/{id}/confirm` → `{"status": "executed"|"failed", "message": str}` (also appended as an assistant message to the action's session); 404/409/410 per Task 5.
  - `POST /pending/{id}/cancel` → `{"status": "cancelled"}`.
  - `GET /log?limit=50` → newest first.
  - `GET /voice-updates?since=<ISO>` → `{"messages": [{"session_id", "role", "content", "timestamp", "pending_action"}], "now": ISO}` — assistant messages of the user's voice session newer than `since`.
  - Provider not configured → 503 with "Composio is not configured".

- [ ] **Step 1: Write the failing tests** calling the endpoint functions with fakes (provider dependency overridable via `get_action_provider`): each route's success shape, 404/409/410 mapping, 503 when unconfigured, `voice-updates` filters by timestamp.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(actions): toolkits, confirmations, log and voice updates API`.

### Task 10: Voice requests

**Files:**
- Create: `backend/app/actions/voice.py`, `backend/app/workers/voice_requests.py`
- Modify: `backend/app/workers/main.py` (enqueue on wake, start the loop), `backend/app/services/analysis_pipeline.py` (extraction uses `text_before_wake(text)`; chunks keep full text)
- Test: `backend/tests/test_voice_requests.py`

**Interfaces:**
- Produces (`voice.py`): `find_wake(text: str) -> int | None` (index of the command start after the name, `None` if not addressed); `text_before_wake(text: str) -> str`; `async is_assistant_request(llm, text: str) -> bool`; `async collect_command(db, wake_segment, now) -> str | None` (`None` = wait; uses Global Constraints window; returns `None` while a segment in the window is still `pending/processing` and `now < wake.received_at + 25 s`); `async get_or_create_voice_session(db, user_id) -> ChatSession` (title "Voice requests", kind "voice").
- Produces (`voice_requests.py`): Redis list `queue:voice` of segment ids; `async process_voice_queue(redis_client, shutdown_event)` polls every 2 s, re-queues not-ready items, runs `run_action_agent(source="voice")` when ready (falls back to RAG answer via `retrieve_memory_context` + LLM when no toolkit is connected), appends user+assistant messages **with ISO timestamps** to the voice session.

- [ ] **Step 1: Write the failing tests**:
  - `find_wake`: "Echo, segnami il dentista" → command "segnami il dentista"; "ehi eco riassumimi le mail" → found; "ecografia domani", "l'eco della stanza", "ho comprato un Echo" (after the LLM check returns False) → no request *(Review Focus 3)*; name after more than 4 words → `None`.
  - `collect_command` joins following segments until `silence_before_ms >= 3000`, stops at 15 s, waits while STT is pending, gives up waiting after 25 s.
  - The worker appends both messages with timestamps to one "Voice requests" session and leaves the wake segment's extraction text without the command (`text_before_wake("Ok. Echo, segnami X") == "Ok."`).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement**; in `process_stt`, after saving a meaningful transcription, `find_wake` → `lpush("queue:voice", segment_id)`; register `process_voice_queue` in `main()` and in `stop_tasks`.
- [ ] **Step 4: Run** — PASS; full suite unchanged otherwise.
- [ ] **Step 5: Commit** `feat(voice): "Echo, …" voice requests answered in chat`.

### Task 11: Remove automatic integrations, Rules and the old calendar path

**Files:**
- Delete: the backend files listed under "removed" in File Structure, their tests (`test_integration_clients.py`, `test_calendar_events.py`, `test_chat_calendar_lookup.py`, `test_oauth_state.py`, `test_oauth_routes.py`, rules/integration parts of `test_timezone_digest_rules.py`), `app/integrations/providers.json`.
- Create: `backend/alembic/versions/008_drop_rules_integrations.py`
- Modify: `backend/app/main.py`, `backend/app/services/analysis_pipeline.py` (drop `allow_side_effects` and the trigger/rules calls), `backend/app/core/config.py`, `.env.example`, `README.md` (actions API, Composio setup: create an API key, `COMPOSIO_API_KEY`, connect accounts from Integrations), `docs/PROJECT-STATUS.md`, `docs/schema.sql` (drop the two tables)
- Test: `backend/tests/test_worker_pipeline.py` (expected call order without integration/rules)

- [ ] **Step 1: Update the pipeline test** to the call order without `integration`/`rules`; run — FAIL.
- [ ] **Step 2: Delete and edit**; migration 008 drops `rules` and `integrations` if present (`down_revision = "007"`; downgrade recreates nothing and documents it).
- [ ] **Step 3: Run** `ruff check app/ tests/` and `pytest tests -q --noconftest` — PASS apart from the known failure/fixture errors; `grep -rn "rules_engine\|trigger_integrations\|calendar_service\|chat_actions\|oauth" app` returns nothing.
- [ ] **Step 4: Commit** `refactor!: replace automatic integrations and rules with Composio actions`.

### Task 12: Mobile API and models

**Files:**
- Create: `mobile/lib/models/action_models.dart`
- Modify: `mobile/lib/services/api_service.dart`, `mobile/lib/models/chat_message.dart`, `mobile/lib/models/chat_session.dart`
- Test: `mobile/test/services/api_service_test.dart`, `mobile/test/models/chat_session_test.dart`

**Interfaces:**
- Produces (Dart): `Toolkit(slug, name, description, connected)`, `PendingAction(id, summary, status, expiresAt)`, `ActionLogEntry(tool, toolkit, argumentsSummary, outcome, error, createdAt)`, `VoiceUpdates(messages: List<ChatSessionMessage>, now: DateTime)`; `ChatMessage.pendingAction`, `ChatSessionMessage.pendingAction`, `ChatSessionSummary.kind`; `QueryResponse.pendingAction`.
- `ApiService`: `getToolkits({String? query})`, `connectToolkit(String slug) -> Future<String>` (url), `disconnectToolkit(String slug)`, `confirmPendingAction(String id) -> Future<String>` (message), `cancelPendingAction(String id)`, `getActionLog()`, `getVoiceUpdates(DateTime? since)`. Remove `getRules`, `getRuleTemplates`, `createRule`, `updateRule`, `deleteRule`, `getAvailableProviders`, `getUserIntegrations`, `createIntegration`, `updateIntegration`, `getOAuthUrl`.

- [ ] **Step 1: Write the failing tests** (stub client): each method's URL/method/body and parsing; 409/410 on confirm map to `ApiException` codes `conflict`/`expired` (add the codes); `pending_action` parsed in query responses and session detail; `kind` parsed with default `"chat"`.
- [ ] **Step 2: Run** `flutter test test/services/api_service_test.dart test/models/chat_session_test.dart` — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(mobile): actions API client and models`.

### Task 13: Mobile chat — action cards and pinned voice session

**Files:**
- Create: `mobile/lib/widgets/action_card.dart`
- Modify: `mobile/lib/services/chat_controller.dart`, `mobile/lib/screens/chat_screen.dart`, `mobile/lib/screens/chat_history_screen.dart`, `mobile/lib/widgets/message_bubble.dart`
- Test: `mobile/test/screens/chat_screen_test.dart`, `mobile/test/services/chat_controller_test.dart`

**Interfaces:**
- Consumes: Task 12.
- Produces: `ActionCard(action: PendingAction, onConfirm, onCancel, busy: bool)`; `ChatController.confirmAction(String id)`, `cancelAction(String id)` updating the message's action status and appending the result message.

- [ ] **Step 1: Write the failing tests**: a message with a pending action shows the summary with **Confirm** and **Cancel**; Confirm calls the API once (button disabled while busy) and shows "Done" / the error; expired (410) shows "This request expired. Ask again."; a non-pending status shows no buttons; the history list shows "Voice requests" first with a pin icon.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(mobile): confirm actions from the chat`.

### Task 14: Mobile Integrations and Activity

**Files:**
- Modify: `mobile/lib/screens/integrations_screen.dart` (rewrite), `mobile/lib/screens/settings/automations_settings_screen.dart`
- Create: `mobile/lib/screens/action_log_screen.dart`
- Delete: `mobile/lib/screens/rules_screen.dart`
- Test: `mobile/test/screens/integrations_screen_test.dart`, `mobile/test/screens/settings_screen_test.dart`

- [ ] **Step 1: Write the failing tests**: the six initial toolkits listed with Connected/Connect; Connect opens the returned URL (injectable launcher) and refreshes on resume; Disconnect asks for confirmation; search shows other toolkits; "Composio is not configured" (503) shows a setup message; Automations shows Integrations and Activity, no Rules; Activity lists log entries newest first with errors in red.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(mobile): Composio integrations and activity log`.

### Task 15: Mobile voice-answer notifications

**Files:**
- Create: `mobile/lib/services/voice_updates_service.dart`
- Modify: `mobile/lib/services/notification_service.dart`, `mobile/lib/services/app_lifecycle_coordinator.dart`
- Test: `mobile/test/services/voice_updates_service_test.dart`

**Interfaces:**
- Produces: `VoiceUpdatesService(api, notifications, preferences)` with `Future<void> check()`: calls `getVoiceUpdates(lastSeen)`, shows one local notification per new assistant message (title "Echo", body = first 120 chars), stores `now` as `lastSeen` in SharedPreferences key `voice_updates_last_seen`; concurrent calls coalesce. `NotificationService.showVoiceAnswer(String preview)`.

- [ ] **Step 1: Write the failing tests**: first check with no stored timestamp only stores `now` (no notification flood); new messages → one notification each, truncated to 120 chars; failures are swallowed and `lastSeen` is not advanced; two concurrent `check()` calls make one request.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement**; the coordinator calls `check()` on every `segmentUploadedStream` event and on `AppLifecycleState.resumed`; tapping the notification opens the Voice requests session.
- [ ] **Step 4: Run** `flutter test` — PASS.
- [ ] **Step 5: Commit** `feat(mobile): notify voice answers at the next wake`.
