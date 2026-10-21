# Web Search and Routines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Echo searches the web when a question needs live information (counted and capped per user), and runs user-defined routines at their time, delivering the answer as a phone notification.

**Architecture:** OpenAI's hosted `web_search` tool is offered to the Responses-API calls Echo already makes (memory answers, voice answers, the action agent), behind a small provider interface so Perplexity can replace it. Routines are rows the action agent creates; a worker loop runs the due ones through the agent (no confirm-tier tools), writes the answer into a pinned "Routines" chat and nudges the phone through the device-command queue it already long-polls.

**Tech Stack:** Python 3.11, FastAPI 0.115, SQLAlchemy async + Alembic, openai 2.54 (Responses API), Redis; Flutter (iOS + Android).

**Spec:** `docs/superpowers/specs/2026-10-21-web-search-and-routines-design.md`

## Global Constraints

- Web search is offered only while the user is under `WEB_SEARCHES_PER_DAY` (default 30) searches that UTC day; without it the "live information" rule says Echo cannot see live information.
- Every search is recorded in `llm_usage` (kind `web_search`, model = provider name, `input_units` = searches).
- Answers from the web are never written into the memory (no entities, chunks or summaries).
- Routines never use confirm-tier tools; at most 10 per user; at most once a day per routine; times in the routine's time zone, stored UTC.
- App UI copy in English; the AI answers in the user's language.
- Run one test suite at a time; TDD; commit to main and push when verified (no branches).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A daylight-saving change between two runs: a 7:00 routine stays at 7:00 local — test in Task 4.
2. Two worker processes at 7:00: the routine runs once — test in Task 5 (claim with `SKIP LOCKED`).
3. The cap reached in the middle of a stream: the answer still completes; the next question gets no search tool — test in Task 2.
4. A search that fails (provider error): the answer says it could not look it up, never invents — test in Task 2.
5. The phone not running at 7:00: the answer waits in the Routines chat and is notified at the next voice-updates check — test in Task 6.

---

### Task 1: The search provider, counting and the cap

**Files:**
- Create: `backend/app/services/web_search.py`, `backend/tests/test_web_search.py`
- Modify: `backend/app/core/config.py` (`web_search_provider: str = "openai"`, `web_searches_per_day: int = 30`), `backend/app/services/llm_base.py` (`LLMResponse.citations`), `backend/app/services/llm_openai.py`, `backend/app/usage_prices.py`, `backend/app/services/usage_report.py` (unit `search`), `.env.example`, README Configuration table

**Interfaces:**
- Produces:
  - `class WebSearchProvider(Protocol)`: `name: str`; `def hosted_tool(self) -> dict | None` (the Responses tool to offer).
  - `class OpenAIWebSearch`: `name = "openai"`, `hosted_tool() -> {"type": "web_search"}`.
  - `def get_web_search_provider() -> WebSearchProvider | None` (None with `web_search_provider == "none"`).
  - `async def search_tool_for(user_id: uuid.UUID, session_factory=None) -> dict | None`: the provider's tool if the user's `web_search` units today (UTC) `< settings.web_searches_per_day`, else None; any DB error → None.
  - `LLMResponse.citations: list[dict] = field(default_factory=list)` — `{"title", "url"}` from `url_citation` annotations, de-duplicated by URL.
  - `OpenAIResponsesLLMService.complete(…, hosted_tools: list[dict] | None = None)`, `.stream(…, hosted_tools=None, on_citations=None)`, `.complete_with_tools(…, hosted_tools=None)`: the hosted tools are appended to `tools`; each `web_search_call` in `response.output` (or each `response.web_search_call.completed` event in a stream) is counted and recorded once per call as `record_usage("web_search", "openai", input_units=n)`; citations are collected from `output_text` annotations (stream: from the `response.completed` event's output) and returned / passed to `on_citations(list[dict])`. `OpenAILLMService` (chat completions) accepts `hosted_tools` and ignores it.
  - `PRICES["openai-web-search"] = {"unit": "search", "per_search": 0.010}` (unverified, like the rest); `usage_report.cost()` handles `unit == "search"`; the report's model for searches is `"openai"` → map kind `web_search` + model `openai` to that price key.

- [ ] **Step 1: Write the failing tests** (`tests/test_web_search.py`, fake Responses client as in `test_usage_recording.py`):
  - `test_the_tool_is_offered_under_the_cap` / `test_no_tool_at_the_cap` (rows in `llm_usage` with 30 `web_search` units today → None) / `test_no_tool_with_provider_none`.
  - `test_searches_are_counted_and_citations_collected` (complete with two `web_search_call` items and a message with two `url_citation` annotations, one URL twice → recorded `("web_search","openai",2,0,0)`, `citations` has 2 entries).
  - `test_a_stream_counts_searches_and_hands_the_citations` (events `response.web_search_call.completed` ×1, text deltas, `response.completed` with annotations → one record, `on_citations` called once, text unchanged).
  - `test_chat_completions_ignore_hosted_tools`.
  - `test_search_cost_in_the_report` (1000 searches → `$10.00`).
- [ ] **Step 2: Run** `sh bt.sh tests/test_web_search.py` — expect FAIL (module missing).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `sh bt.sh tests/test_web_search.py tests/test_usage_recording.py tests/test_usage_report.py` — PASS.
- [ ] **Step 5: Commit** `feat(server): web search tool, counted and capped per user`.

### Task 2: Search in answers (chat, stream, voice, agent)

**Files:**
- Modify: `backend/app/services/memory_answers.py` (rule 4 when searching), `backend/app/routers/query.py` (both branches, `QueryResponse.web_sources`), `backend/app/workers/voice_requests.py` (`_memory_answer`), `backend/app/actions/agent.py` (hosted tool next to the function tools), `backend/evals/cases/answers.json`, `mobile/lib/models/chat_message.dart` / chat parsing (web sources), `mobile/lib/widgets/message_bubble.dart` (web links open in the browser)
- Test: `backend/tests/test_web_answers.py`, `mobile/test/widgets/web_sources_test.dart`

**Interfaces:**
- Consumes: `search_tool_for`, `hosted_tools`, `citations` (Task 1).
- Produces:
  - `rag_system_prompt(date_range, about="", language=None, can_search=False)`: with `can_search`, rule 4 reads "search the web, answer from what you found and name the sources; if the search finds nothing, say so"; without, today's rule.
  - `QueryResponse.web_sources: list[{"title": str | None, "url": str}] = []`, also in the stream's `done` event and stored with the assistant message (`"web_sources"`) so history shows them.
  - The memory answer (chat complete and stream, empty-memory branch included), the voice memory answer and the agent pass `hosted_tools=[tool]` when `search_tool_for(user)` gives one. Nothing from `citations` reaches entities, chunks or summaries.
  - App: `ChatMessage.webSources` (`List<({String? title, String url})>`); the answer panel lists them under "From the web" as the domain and title, tapping opens `url` externally.

- [ ] **Step 1: Write the failing tests:**
  - `test_a_live_question_offers_the_search_tool` (mock LLM capturing `hosted_tools`; prompt contains the search wording) / `test_at_the_cap_the_prompt_says_no_live_information`.
  - `test_web_sources_reach_the_response_and_the_history` (mock returns citations → `web_sources` in `/api/query` and in `GET /api/chat-sessions/{id}`).
  - `test_the_stream_done_event_carries_web_sources`.
  - `test_a_failed_search_says_it_could_not_look` (eval case: `answers.json` "che tempo fa domani a Milano?" with search → mentions a source; the mocked failure path: the provider raising → the answer without the tool, fixed rule).
  - `test_voice_answers_and_the_agent_offer_the_tool`.
  - `test_web_text_never_becomes_memory` (after an answer with citations, no new `entities`/`chunks` rows).
  - App `web_sources_test.dart`: a message with two web sources shows "From the web", both domains, and tapping opens the URL (launcher fake).
- [ ] **Step 2: Run** — expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the backend tests above plus `tests/test_query*.py tests/test_voice_requests.py tests/test_action_agent.py`; `flutter test` for the widget; `make eval-llm SUITE=answers` once (real calls) — PASS; note the eval result in the commit.
- [ ] **Step 5: Commit** `feat: Echo searches the web when a question needs live information`.

### Task 3: Routines: table and REST

**Files:**
- Create: `backend/app/models/routine.py`, `backend/alembic/versions/020_routines.py`, `backend/app/routers/routines.py`, `backend/tests/test_routines_api.py`
- Modify: `backend/app/models/__init__.py`, `backend/app/main.py`, `backend/tests/conftest.py` (cleanup), `backend/tests/test_migrations.py`, `docs/schema.sql`, README API reference

**Interfaces:**
- Produces:
  - `Routine` (`routines`): `id`, `user_id`, `instruction text`, `schedule jsonb` (`{"kind": "daily"|"weekdays"|"weekly"|"monthly", "time": "HH:MM", "days": [1-7]?, "day_of_month": 1-28?}`), `timezone varchar(64)`, `active bool`, `next_run_at timestamptz`, `last_run_at`, `last_status varchar(10)` (`ok`|`failed`|`skipped`), `last_answer text`, `source varchar(10)` (`chat`|`voice`), `created_at`; index on `(active, next_run_at)`. `MAX_ROUTINES = 10`.
  - `GET /api/routines` → list (newest first) with a `schedule_text` ("Every day at 07:00", "Weekdays at 08:30", "Every Monday at 09:00", "On the 1st of every month at 08:00"); `PATCH /api/routines/{id}` `{active}` (resuming recomputes `next_run_at`); `DELETE /api/routines/{id}` → 204. Another user's id → 404.

- [ ] **Step 1: Write the failing tests** (`list_is_per_user`, `pause_and_resume_recomputes_next_run`, `delete`, `another_users_routine_is_404`, `schedule_text_reads_naturally`).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** (schedule maths from Task 4's `next_run` — write `services/routines.py::next_run` here with its own tests if Task 4 is not done yet; Task 4 extends it).
- [ ] **Step 4: Run** `sh bt.sh tests/test_routines_api.py tests/test_migrations.py` — PASS.
- [ ] **Step 5: Commit** `feat(server): routines table and REST`.

### Task 4: Creating routines by asking; schedule maths

**Files:**
- Create: `backend/app/services/routines.py`, `backend/tests/test_routines_schedule.py`, `backend/tests/test_routines_agent.py`
- Modify: `backend/app/actions/agent.py` (three tools, offered always), `backend/app/actions/policy.py` (CREATE tier for them), `backend/app/actions/availability.py` / `routers/query.py::might_need_tools` (routine wording routes to the agent), `backend/evals/cases/tools.json`

**Interfaces:**
- Produces:
  - `def next_run(schedule: dict, tz: str, after: datetime) -> datetime` (UTC; local wall time kept across DST; `weekdays` = Mon–Fri; `monthly` day 1–28).
  - `def validate_schedule(schedule: dict) -> dict` (raises `ValueError` with an English message the model can relay).
  - Agent tools `ECHO_CREATE_ROUTINE(instruction: str, kind, time, days?, day_of_month?)`, `ECHO_LIST_ROUTINES()`, `ECHO_DELETE_ROUTINE(routine_id)`; executed in-process (not Composio, not the phone); the 11th → error "At most 10 routines."; creation stores `timezone = settings.user_timezone`, `source` from the caller (chat/voice).
  - Agent prompt rule: "When the user asks for something to happen regularly ('ogni mattina alle 7…', 'every Friday…'), create a routine. If the time or the place (for the weather) is missing, ask; never guess. Confirm in words with the schedule and say it can be paused in Settings → Routines."
  - `might_need_tools` matches routine wording ("ogni", "every", "tutti i giorni", "each morning"…).

- [ ] **Step 1: Write the failing tests:**
  - Schedule: `test_daily_at_seven_is_next_seven_local`, `test_dst_keeps_seven_oclock` (Europe/Rome, 25→26 Oct 2026), `test_weekdays_skip_the_weekend`, `test_weekly_on_given_days`, `test_monthly_day`, `test_bad_schedules_are_refused`.
  - Agent (mock LLM scripted tool calls as in `test_action_agent.py`): `test_the_agent_creates_a_routine`, `test_at_most_ten`, `test_list_and_delete`, `test_routine_tools_need_no_connected_app`.
  - Evals (`tools.json`): "ogni mattina alle 7 dimmi che tempo fa a Milano" → `ECHO_CREATE_ROUTINE`; "dimmi il meteo ogni mattina" → no tool call (asks the time/place).
- [ ] **Step 2–4:** FAIL → implement → PASS (`sh bt.sh tests/test_routines_schedule.py tests/test_routines_agent.py tests/test_action_agent.py`; `make eval-llm SUITE=tools` once).
- [ ] **Step 5: Commit** `feat(server): ask Echo for a routine`.

### Task 5: Running routines

**Files:**
- Create: `backend/app/workers/routines.py`, `backend/tests/test_routines_worker.py`
- Modify: `backend/app/workers/main.py` (start the loop), `backend/app/actions/agent.py` (`run_action_agent(…, allow_confirm=True)`), `backend/app/actions/voice.py` (or a shared helper: `get_or_create_routines_session`)

**Interfaces:**
- Consumes: `next_run` (Task 4), `search_tool_for` (Task 1), `push_device_command`.
- Produces:
  - `async def run_due_routines(now: datetime, session_factory, llm, provider_factory) -> int` — claims `active and next_run_at <= now` with `SELECT … FOR UPDATE SKIP LOCKED` (limit 20), and per routine: `owned_by(user_id)`; if `now - next_run_at > 2 h` → `last_status = "skipped"`, no run; else `run_action_agent(instruction, allow_confirm=False, hosted web search)` with a 60 s timeout; appends `{"role": "user", "content": instruction, "routine_id"}` and the assistant answer (`"routine_id"`, `"notify": True`) to the "Routines" chat (`ChatSession.kind == "routines"`, one per user); pushes device command `{"type": "voice_update"}`; sets `last_run_at`, `last_status`, `last_answer`, `next_run_at = next_run(schedule, tz, now)`. A failure → `last_status = "failed"`, the chat gets "This routine could not run." and the next run is still scheduled.
  - `async def run_routines_loop(shutdown_event)` — every 60 s.
  - `run_action_agent(…, allow_confirm: bool = True)`: with False, tools classified `CONFIRM` are not offered.

- [ ] **Step 1: Write the failing tests:** `test_a_due_routine_runs_once_and_is_rescheduled`, `test_two_workers_run_it_once` (two concurrent `run_due_routines` on the same DB), `test_a_routine_more_than_two_hours_late_is_skipped`, `test_no_confirm_tools_in_a_routine`, `test_the_answer_lands_in_the_routines_chat_and_nudges_the_phone`, `test_a_failing_run_is_reported_and_rescheduled`, `test_usage_is_owned_by_the_routines_user`.
- [ ] **Step 2–4:** FAIL → implement → PASS (`sh bt.sh tests/test_routines_worker.py tests/test_action_agent.py tests/test_worker_shutdown.py`).
- [ ] **Step 5: Commit** `feat(server): routines run at their time`.

### Task 6: The phone notification

**Files:**
- Modify: `backend/app/routers/actions.py` (`/voice-updates` reads the `voice` and `routines` sessions), `backend/tests/test_routines_worker.py` or `tests/test_voice_requests.py`, `mobile/lib/models/device_command.dart` (`VoiceUpdateCommand`), `mobile/lib/services/device/device_command_loop.dart` (calls `onVoiceUpdate`), `mobile/lib/services/app/app_lifecycle_coordinator.dart` (wires it to `voiceUpdates.check()`), `mobile/lib/services/chat/voice_updates_service.dart` (notifies the session the message belongs to)
- Test: `mobile/test/services/device/device_command_loop_test.dart`, `mobile/test/services/chat/voice_updates_service_test.dart`

**Interfaces:**
- Produces: `/voice-updates` returns new assistant messages of both sessions, each with its `session_id`; `DeviceCommand.fromJson` parses `{"type": "voice_update"}` → `VoiceUpdateCommand`; the loop runs `onVoiceUpdate()`; the notification's payload opens that session.

- [ ] **Step 1: Write the failing tests:** backend `test_voice_updates_include_routine_answers`; app `a voice_update command runs the updates check`, `a routine answer is notified and opens the Routines chat`, `an unknown command type is ignored`.
- [ ] **Step 2–4:** FAIL → implement → PASS (backend file; `flutter test` on the two files, then all).
- [ ] **Step 5: Commit** `feat: routine answers arrive as a notification`.

### Task 7: Settings → Routines

**Files:**
- Create: `mobile/lib/screens/settings/routines_screen.dart`, `mobile/lib/services/api/routines_api.dart`, `mobile/lib/models/routine.dart`, `mobile/test/screens/routines_screen_test.dart`
- Modify: `mobile/lib/services/api/api_service.dart` (mixin), `mobile/lib/screens/settings_screen.dart` (row "Routines", subtitle "What Echo does on its own, and when."), `mobile/lib/screens/settings/capabilities_screen.dart` (the example), `mobile/README.md`

**Interfaces:**
- Produces: `RoutinesApi { listRoutines(); setRoutineActive(id, active); deleteRoutine(id); }`; the screen lists instruction, `schedule_text`, next run ("Next: tomorrow at 07:00"), last result or "Could not run"; a `Switch` (key `routine-<id>`) pauses; a delete action with confirm; an empty state "Ask Echo to set one up: 'Hey Echo, every morning at 7 tell me the weather in Milan.'"; a line "Results arrive as a notification while Echo is running on this phone, otherwise when you next open it."

- [ ] **Step 1: Write the failing tests:** list, pause calls `setRoutineActive(false)`, delete after confirm, empty state text.
- [ ] **Step 2–4:** FAIL → implement → PASS (`flutter analyze`, `flutter test`).
- [ ] **Step 5: Commit** `feat(mobile): Settings → Routines`.

### Task 8: Close the loop

- [ ] **Step 1:** Whole backend suite, `ruff check app tests evals`, `flutter test`, `flutter build ios --debug --no-codesign` and `flutter build apk --debug` — one at a time — all pass.
- [ ] **Step 2:** `docs/ROADMAP.md` (tick web search and routines; Perplexity as the next provider), `docs/PROJECT-STATUS.md` (the two features, the notification limit, the search cap and price to verify).
- [ ] **Step 3: Commit** `docs: web search and routines in status and roadmap`; push.
