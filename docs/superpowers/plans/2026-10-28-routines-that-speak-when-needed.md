# Routines that speak only when needed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Routines get a mode (always / only if / only what's new), each run becomes its own record, quiet runs stay quiet, and results show in Today, in Ask → Routines and in Profile, always readable in full.

**Architecture:** A new `routine_runs` table is the single source for results. The worker writes one run per execution (no more thread messages), using a small pure module (`services/routine_results.py`) to frame the request, parse the agent's JSON result, filter already-seen items and compose the text. New endpoints list runs and add one to the thread ("Ask about this"); `/api/voice-updates` also returns new runs so the phone notifies them. The app adds a run model and API, a full-text sheet, a Today panel, a Chat | Routines switch in Ask and run links in Profile → Routines.

**Tech Stack:** FastAPI, SQLAlchemy 2 async, Alembic, Postgres (JSONB), pytest; Flutter (Dart 3), flutter_test.

**Spec:** `docs/superpowers/specs/2026-10-28-routines-that-speak-when-needed-design.md`

## Global Constraints

- Modes are exactly `always`, `only_if`, `only_new`; default `always` (existing routines keep today's behaviour).
- Run statuses are exactly `reported`, `nothing`, `failed`, `skipped`; `routines.last_status` takes the same values (old `ok` rows read as `reported` in the app).
- Next migration id is `026`, revising `025`.
- Runs are kept 90 days (`KEEP_DAYS = 90`, like `services/places.py`), then deleted.
- Routine runs never go into the chat thread, except one the user sends there with "Ask about this".
- Quiet (`nothing`) and `skipped` runs never notify; `reported` and `failed` runs do, through `/api/voice-updates`.
- No APNs; notifications only when the app wakes or opens (existing `VoiceUpdatesService.check`).
- App strings in English; routine texts stay in the user's language.
- No text cut without a way to read it in full: previews with no page behind them use `ExpandableText` (`mobile/lib/widgets/expandable_text.dart`).
- One user: server and app ship together; no compatibility path for older app builds.
- Tests: `make test-all` (backend, Docker) and `cd mobile && flutter analyze && flutter test` must pass.

## Review Focus

1. **The agent answers prose, or JSON wrapped in a code fence, instead of bare JSON** → the run still reports (parse tolerates fences and surrounding text; one conversion retry; then raw text as `reported`). Test: `test_a_fenced_json_answer_is_read` and `test_an_unreadable_answer_is_converted_once_then_reported_raw` (Tasks 2, 3).
2. **The same job opening comes back with a different link (tracking query, trailing slash, `http` vs `https`)** → treated as seen. Test: `test_item_key_ignores_query_fragment_scheme_and_trailing_slash` (Task 2).
3. **A routine's every item was already seen** → `nothing`, no notification, no text in Today. Test: `test_only_new_with_only_seen_items_is_nothing_and_not_nudged` (Task 3).
4. **"Ask about this" tapped twice on the same run** → one message in the thread. Test: `test_ask_about_a_run_adds_it_to_the_thread_once` (Task 5).
5. **Today panel on a day with only quiet runs** → the panel shows only "N checked, nothing new", not an empty list. Test: `today panel with only quiet runs shows one muted line` (Task 9).

---

## File map

Backend
- Create `backend/alembic/versions/026_routine_runs.py` — `routines.mode`, table `routine_runs`.
- Create `backend/app/models/routine_run.py`; modify `backend/app/models/routine.py`, `backend/app/models/__init__.py`.
- Create `backend/app/services/routine_results.py` — pure: framing, parsing, keys, filtering, composing.
- Create `backend/app/services/routine_runs.py` — DB: record a run, seen items, cleanup.
- Modify `backend/app/workers/routines.py` — modes, runs, nudges, daily cleanup.
- Modify `backend/app/actions/routine_tools.py` — `mode` in create and list.
- Modify `backend/app/routers/routines.py` (`mode`), create `backend/app/routers/routine_runs.py`, modify `backend/app/main.py`, `backend/app/routers/actions.py` (`/voice-updates`).

App
- Modify `mobile/lib/models/routine.dart`; create `mobile/lib/models/routine_run.dart`.
- Modify `mobile/lib/services/api/routines_api.dart`, `mobile/lib/models/action_models.dart` (`VoiceUpdates`).
- Modify `mobile/lib/services/chat/voice_updates_service.dart`, `mobile/lib/services/app/notification_service.dart`, `mobile/lib/services/app/app_controller.dart`.
- Create `mobile/lib/widgets/routine_run_sheet.dart`, `mobile/lib/widgets/routine_sections.dart`.
- Modify `mobile/lib/screens/home_screen.dart`, `mobile/lib/screens/chat_screen.dart`; create `mobile/lib/screens/routine_runs_view.dart`.
- Modify `mobile/lib/screens/settings/routines_screen.dart`.

---

### Task 1: Runs and modes in the database

**Files:**
- Create: `backend/alembic/versions/026_routine_runs.py`, `backend/app/models/routine_run.py`
- Modify: `backend/app/models/routine.py`, `backend/app/models/__init__.py`, `docs/schema.sql`
- Test: `backend/tests/test_routine_runs_model.py`

**Interfaces:**
- Produces: `Routine.mode: Mapped[str]` (String(10), not null, server default `'always'`); `RoutineRun` with `id` (UUID pk), `routine_id` (FK `routines.id` ON DELETE CASCADE, indexed), `user_id` (UUID, indexed), `ran_at` (timestamptz), `status` (String(10)), `text` (Text, nullable), `sources` (JSONB, default `[]`), `items` (JSONB, default `[]`); index `ix_routine_runs_user_ran` on (`user_id`, `ran_at`).

- [ ] **Step 1: Write the failing tests**

```python
async def test_a_routine_is_always_by_default(db_session): ...
    # a Routine added without mode reads back with mode == "always"

async def test_runs_go_with_their_routine(db_session): ...
    # a RoutineRun(status="reported", text="Sole", items=[{"key": "k", "title": "t", "url": None}])
    # is stored; after deleting the routine, select(RoutineRun) for it returns nothing
```

- [ ] **Step 2: Run to see them fail**

Run: `docker compose exec -T -e DATABASE_URL=postgresql+asyncpg://echo:echo@postgres:5432/echo_test api python -m pytest tests/test_routine_runs_model.py -q`
Expected: FAIL (`ImportError: cannot import name 'RoutineRun'`)

- [ ] **Step 3: Implement the migration and models**

Migration `026` (revises `025`): add `routines.mode` with `server_default="always"`; create `routine_runs` with the columns above and `ondelete="CASCADE"`; downgrade drops both. Model docstring in the style of `models/routine.py`; `RoutineRun` exported from `models/__init__.py`. Add the table and column to `docs/schema.sql`.

- [ ] **Step 4: Migrate the test DB and run the tests**

Run: `make test-all` (it runs `alembic upgrade head` on `echo_test` first)
Expected: the two new tests PASS, nothing else breaks.

- [ ] **Step 5: Commit** — `feat(server): routine runs and modes (migration 026)`

---

### Task 2: Reading and writing a run's result (pure)

**Files:**
- Create: `backend/app/services/routine_results.py`
- Test: `backend/tests/test_routine_results.py`

**Interfaces:**
- Produces:
  - `MODES = ("always", "only_if", "only_new")`
  - `@dataclass(frozen=True) class RoutineResult: report: bool; text: str; items: list[dict]` (each item `{"key", "title", "line", "url"}`)
  - `framed_request(instruction: str, mode: str, seen: list[dict]) -> str` — `always`: the instruction unchanged. Otherwise the instruction plus the answer contract: reply with JSON only, `{"report": bool, "intro": str, "text": str, "items": [{"title", "line", "url"}]}`; `only_if`: `report` true only when the condition in the instruction holds, `text` the message; `only_new`: one item per thing found, and the titles/links in `seen` (at most `SEEN_IN_PROMPT = 50`) are listed as already reported.
  - `parse_result(answer: str, mode: str) -> RoutineResult | None` — reads the first JSON object in the answer (bare, or inside a ``` fence, or with text around it); None when there is none or `report` is not a bool. Items get their `key` from `item_key`.
  - `item_key(item: dict) -> str` — from `url` when present: lowercase host, `http`→`https`, no query, no fragment, no trailing `/`; else the title lowercased, punctuation removed, whitespace collapsed.
  - `fresh_items(items: list[dict], seen_keys: set[str]) -> list[dict]` — order kept, duplicates within `items` dropped too.
  - `compose_text(intro: str, items: list[dict]) -> str` — intro (if any) then one line per item: `• {title} — {line}` plus ` {url}` when there is one.
  - `CONVERT_PROMPT: str` — the instruction for the one conversion retry (Task 3).

- [ ] **Step 1: Write the failing tests**

```python
def test_always_is_the_instruction_unchanged(): ...
def test_only_new_lists_what_was_already_reported(): ...       # titles of `seen` appear, at most 50
def test_a_bare_json_answer_is_read(): ...
def test_a_fenced_json_answer_is_read(): ...                   # ```json {...} ``` with prose around
def test_no_json_or_a_report_that_is_not_a_bool_is_none(): ...
def test_item_key_ignores_query_fragment_scheme_and_trailing_slash():
    assert item_key({"url": "http://Jobs.example.com/a/?utm=1#x", "title": "A"}) == \
        item_key({"url": "https://jobs.example.com/a", "title": "B"})
def test_item_key_without_a_link_is_the_normalized_title():
    assert item_key({"url": None, "title": "  Backend  Engineer, Satispay!"}) == \
        item_key({"url": "", "title": "backend engineer satispay"})
def test_fresh_items_drops_seen_and_repeated(): ...
def test_compose_text_is_the_intro_then_one_line_per_item():
    assert compose_text("2 nuove posizioni:", [
        {"title": "Backend Engineer", "line": "Satispay, Milano", "url": "https://x.io/1"},
        {"title": "Platform Dev", "line": "remoto", "url": None},
    ]) == "2 nuove posizioni:\n• Backend Engineer — Satispay, Milano https://x.io/1\n• Platform Dev — remoto"
```

- [ ] **Step 2: Run to see them fail** — `pytest tests/test_routine_results.py -q` (no DB needed; `--noconftest` works) → FAIL, module missing.
- [ ] **Step 3: Implement `services/routine_results.py`** — stdlib only (`json`, `re`, `urllib.parse`).
- [ ] **Step 4: Run to see them pass** — same command → PASS.
- [ ] **Step 5: Commit** — `feat(server): routine results: framing, parsing, seen items`

---

### Task 3: The worker writes runs, by mode

**Files:**
- Create: `backend/app/services/routine_runs.py`
- Modify: `backend/app/workers/routines.py`
- Test: `backend/tests/test_routines_worker.py` (rewrite the thread assertions), `backend/tests/test_routine_runs_service.py`

**Interfaces:**
- Consumes: Task 1 models; Task 2 `framed_request`, `parse_result`, `fresh_items`, `compose_text`, `CONVERT_PROMPT`.
- Produces:
  - `services/routine_runs.py`: `KEEP_DAYS = 90`; `async def seen_items(db, routine_id) -> list[dict]` (items of the routine's runs, newest first, at most 200, no duplicates by key); `async def record_run(db, routine: Routine, *, status: str, ran_at: datetime, text: str | None = None, sources: list[dict] | None = None, items: list[dict] | None = None) -> RoutineRun` (adds the run, sets `routine.last_run_at`, `last_status`, and `last_answer` to `text` when there is one; does not commit); `async def delete_old_runs(db, now: datetime) -> int` (commits).
  - Worker: `_Due` gains `mode: str`; `_run_one` records exactly one run; skipped routines in `_claim` record a `skipped` run.

- [ ] **Step 1: Write the failing tests** (in `test_routines_worker.py`; the `_LLM` fake already returns `self.answer` or queued `responses`)

```python
async def test_an_always_routine_reports_its_answer_as_a_run_not_in_the_thread():
    # run with answer "Oggi a Milano sole, 19 °C." → one RoutineRun(status="reported", text=that),
    # the thread has no new message, routine.last_status == "reported", the phone is nudged

async def test_only_if_that_does_not_hold_is_nothing_and_not_nudged():
    # mode="only_if", answer '{"report": false, "intro": "", "text": "", "items": []}'
    # → status "nothing", text None, no "voice_update" command in Redis

async def test_only_if_that_holds_reports_its_text(): ...   # report true, text "Domani piove dalle 15"

async def test_only_new_reports_only_items_not_seen_before():
    # a previous run of the routine has items with key of https://x.io/1;
    # answer lists https://x.io/1 and https://x.io/2 → run text == compose_text(intro, [item 2]),
    # run.items has only item 2's key

async def test_only_new_with_only_seen_items_is_nothing_and_not_nudged(): ...

async def test_only_new_tells_the_agent_what_it_already_reported():
    # the request given to the agent (llm.call_log) contains the seen item's title

async def test_an_unreadable_answer_is_converted_once_then_reported_raw():
    # mode="only_if"; responses: agent answers "Piove domani" (no JSON);
    # the conversion call (llm.complete) also returns no JSON → status "reported", text "Piove domani";
    # exactly one llm.complete call

async def test_a_converted_answer_is_used(): ...   # conversion returns valid JSON with report false → "nothing"

async def test_a_failed_run_is_recorded_and_nudged(): ...   # agent raises → status "failed", text FAILED["it"]

async def test_a_late_routine_records_a_skipped_run(): ...  # next_run_at 3 h before NOW → run status "skipped"
```

In `test_routine_runs_service.py`: `test_seen_items_are_the_routines_own_newest_first_without_repeats`, `test_old_runs_are_deleted_after_90_days`.

- [ ] **Step 2: Run to see them fail** — `pytest tests/test_routines_worker.py tests/test_routine_runs_service.py -q` → FAIL.
- [ ] **Step 3: Implement**
  - `_run_one`: for `always`, the agent's answer is the text (`reported`); otherwise run the agent on `framed_request(...)` (with `seen_items` for `only_new`), `parse_result`; on None one `llm.complete([system CONVERT_PROMPT, user answer])` and `parse_result` again; still None → `reported` with the raw answer. `only_new` keeps `fresh_items(result.items, seen keys)`; none left → `nothing`; else text `compose_text(intro, fresh)`. `only_if`: `report` false → `nothing`, else `reported` with `text` (fallback `intro`). Sources = `outcome.web_sources`. The conversion call happens inside the same `asyncio.wait_for` budget (`RUN_TIMEOUT_S`) as the agent.
  - No more `get_or_create_voice_session` / thread writes. Nudge (`voice_update`) only after `reported` and `failed`.
  - `run_routines_loop`: call `delete_old_runs` at most once per UTC day (remember the last date in the loop).
- [ ] **Step 4: Run to see them pass** — `make test-all` → all PASS (old thread-based worker tests removed or rewritten to runs).
- [ ] **Step 5: Commit** — `feat(server): routines record runs and speak only when needed`

---

### Task 4: The agent creates routines with a mode

**Files:**
- Modify: `backend/app/actions/routine_tools.py`
- Test: `backend/tests/test_routines_agent.py`

**Interfaces:**
- Produces: `ECHO_CREATE_ROUTINE` parameter `mode` (`enum: ["always", "only_if", "only_new"]`, optional, default `always`) with the description: a condition ("se piove", "if it is below zero") → `only_if`; "new", "nuove", "se ci sono novità" → `only_new`; otherwise `always`. The tool result for create and every item of `ECHO_LIST_ROUTINES` include `"mode"` and `"mode_text"` (`"always tells you"`, `"tells you only if the condition holds"`, `"tells you only what is new"`) so the model can say it in the user's language.

- [ ] **Step 1: Write the failing tests**

```python
async def test_create_stores_the_mode(): ...            # tool call with mode "only_new" → Routine.mode == "only_new"
async def test_create_without_a_mode_is_always(): ...
async def test_an_unknown_mode_is_refused(): ...        # ToolResult ok False, nothing created
async def test_the_list_says_each_mode(): ...
```

- [ ] **Step 2: Run to see them fail** — `pytest tests/test_routines_agent.py -q` → FAIL.
- [ ] **Step 3: Implement** in `run_routine_tool` (validate against `MODES` from Task 2).
- [ ] **Step 4: Run to see them pass** → PASS.
- [ ] **Step 5: Commit** — `feat(server): the agent picks a routine's mode`

---

### Task 5: Runs over the API; "Ask about this"; runs in voice updates

**Files:**
- Create: `backend/app/routers/routine_runs.py`
- Modify: `backend/app/routers/routines.py`, `backend/app/main.py`, `backend/app/routers/actions.py`
- Test: `backend/tests/test_routine_runs_api.py`, `backend/tests/test_routines_api.py`, `backend/tests/test_actions_router_http.py` (where `/voice-updates` is tested today)

**Interfaces:**
- Produces:
  - `RoutineOut.mode: str`.
  - `GET /api/routine-runs?routine_id=&since=&before=&limit=` → `{"items": [RunOut], "next_before": datetime | null}`; newest first; `limit` default 30, max 100; `since`/`before` compare `ran_at` (`>=` / `<`); only the caller's runs. `RunOut`: `id, routine_id, instruction, mode, schedule_text, ran_at, status, text, sources`.
  - `POST /api/routine-runs/{id}/ask` → `{"session_id": str}`: appends to the thread (`get_or_create_voice_session`) one assistant message `{"role": "assistant", "content": run.text, "timestamp": now, "routine_id", "routine_run_id", "routine_schedule", "citations": run.sources, "notify": False}` unless a message with that `routine_run_id` is already there; 404 for another user's run; 409 for a run with no text (`nothing`, `skipped`).
  - `/api/voice-updates` response gains `"routine_runs": [{"id", "routine_id", "status", "text", "ran_at"}]` — the caller's `reported` and `failed` runs with `ran_at > since`; with no `since` it is `[]` (the app's first check only sets its clock, as for messages).

- [ ] **Step 1: Write the failing tests**

```python
async def test_runs_are_the_users_own_newest_first_with_their_routine(client, auth_headers): ...
async def test_runs_filter_by_routine_and_since_and_page_with_before(...): ...
async def test_ask_about_a_run_adds_it_to_the_thread_once(...):
    # two POSTs → one message with routine_run_id in the thread; "notify" is False
async def test_the_next_question_has_the_run_in_its_history(...):
    # after POST /ask, load_thread_history for the thread ends with the run's text
async def test_ask_about_a_quiet_run_is_409(...): ...
async def test_ask_about_someone_elses_run_is_404(...): ...
async def test_voice_updates_bring_new_reported_and_failed_runs_only(...): ...  # nothing/skipped absent
async def test_the_routines_list_has_each_mode(...): ...   # in test_routines_api.py
```

- [ ] **Step 2: Run to see them fail** → FAIL.
- [ ] **Step 3: Implement** the router (registered in `main.py` like the others) and the two changes.
- [ ] **Step 4: Run** `make test-all` and `make lint` → PASS, clean.
- [ ] **Step 5: Commit** — `feat(server): routine runs API, "Ask about this", runs in voice updates`

---

### Task 6: The app knows runs and modes

**Files:**
- Create: `mobile/lib/models/routine_run.dart`
- Modify: `mobile/lib/models/routine.dart`, `mobile/lib/services/api/routines_api.dart`, `mobile/lib/models/action_models.dart`
- Test: `mobile/test/models/routine_run_test.dart`, `mobile/test/services/api/api_service_test.dart`

**Interfaces:**
- Produces:
  - `Routine.mode` (`String`, `'always'` when missing); `String routineModeText(String mode)` → `'Always tells you'`, `'Tells you only if…'` (for `only_if`), `'Tells you only what is new'`; `Routine.lastStatus` maps `'ok'` to `'reported'` when parsed.
  - `@immutable final class RoutineSource { String title; Uri? url; }` and `@immutable final class RoutineRun { id, routineId, instruction, mode, scheduleText, ranAt (local), status, text?, List<RoutineSource> sources; bool get hasText }`, both with `fromJson` (a source without a valid `http(s)` url keeps `url` null).
  - `final class RoutineRunPage { List<RoutineRun> items; DateTime? nextBefore; }`
  - In `RoutinesApi`: `Future<RoutineRunPage> listRoutineRuns({String? routineId, DateTime? since, DateTime? before, int limit = 30});` and `Future<String> askAboutRoutineRun(String runId);` (returns the thread's session id).
  - `VoiceUpdates.routineRuns: List<RoutineRunUpdate>` (`id, routineId, status, text?, ranAt`), empty when the field is missing.

- [ ] **Step 1: Write the failing tests** — parsing (`ok` → `reported`; missing `mode` → `always`; sources), the two endpoints' paths and query parameters (`since`/`before` sent as UTC ISO), `VoiceUpdates` with and without `routine_runs`.
- [ ] **Step 2: Run** `flutter test test/models/routine_run_test.dart test/services/api/api_service_test.dart` → FAIL.
- [ ] **Step 3: Implement**; every existing fake implementing `RoutinesApi` gets the two methods (`grep -rln "implements.*RoutinesApi\|RoutinesApi" mobile/test`).
- [ ] **Step 4: Run** `flutter analyze && flutter test` → PASS.
- [ ] **Step 5: Commit** — `feat(mobile): routine runs and modes in the app's models and API`

---

### Task 7: Notifications and navigation for runs

**Files:**
- Modify: `mobile/lib/services/chat/voice_updates_service.dart`, `mobile/lib/services/app/notification_service.dart`, `mobile/lib/services/app/app_controller.dart`
- Test: `mobile/test/services/chat/voice_updates_service_test.dart`, `mobile/test/services/app/app_controller_test.dart`

**Interfaces:**
- Produces:
  - `NotificationService.showRoutineRun(String preview, {required String runId, required int id})` with payload `'routines:<runId>'`; failed runs use the preview `'A routine could not run'`.
  - `VoiceUpdatesService` notifies each new run of `updates.routineRuns` once (seen key `'run:<id>'` in the same `seenKeysKey` list) and calls a new `onNewRuns` callback once per check that found some.
  - `enum AskView { chat, routines }`; in `AppController`: `final ValueNotifier<AskView> askView` (starts `chat`), `final ValueNotifier<String?> routinesFilter`, `final ValueNotifier<int> routineRunsChanged`; `void requestOpenRoutines({String? routineId})` (sets filter and view, selects Ask); `void requestOpenThread()` (view `chat`, `threadChanged()`, selects Ask); `handleNotificationPayload('routines:<id>')` → `requestOpenRoutines()`.

- [ ] **Step 1: Write the failing tests** — a check with two runs notifies twice and not again on the next check; `onNewRuns` called once; a `routines:` payload selects Ask with `askView == AskView.routines`; `requestOpenThread` selects Ask with `AskView.chat` and bumps `threadUpdates`.
- [ ] **Step 2: Run** the two test files → FAIL.
- [ ] **Step 3: Implement**; wire `onNewRuns` to `appController.routineRunsChanged.value++` where `VoiceUpdatesService` is built (`grep -rn "VoiceUpdatesService(" mobile/lib`).
- [ ] **Step 4: Run** `flutter analyze && flutter test` → PASS.
- [ ] **Step 5: Commit** — `feat(mobile): notifications for routine results, open Ask on Routines`

---

### Task 8: A run in full: the sheet

**Files:**
- Create: `mobile/lib/widgets/routine_run_sheet.dart`
- Test: `mobile/test/widgets/routine_run_sheet_test.dart`

**Interfaces:**
- Consumes: `RoutineRun` (Task 6).
- Produces: `Future<void> showRoutineRunSheet(BuildContext context, RoutineRun run, {required Future<void> Function() onAskAbout})` — a scrollable bottom sheet: the routine's instruction and `routineModeText`, the run's time (`formatTime`), the whole text (no `maxLines`), the sources as tappable rows opening the link (`url_launcher`, external), and a button **Ask about this** (`Key('run-ask-about')`, shown only when `run.hasText`) that pops the sheet and calls `onAskAbout`. Failed runs show their text in the error colour; skipped runs show `"Missed at {time}: Echo's server was off"`.

- [ ] **Step 1: Write the failing tests** — a 2,000-character text is fully present (`find.text(longText)`), sources listed, the button calls `onAskAbout` once and closes the sheet, no button for a skipped run.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `flutter test test/widgets/routine_run_sheet_test.dart` → PASS.
- [ ] **Step 5: Commit** — `feat(mobile): a routine result in full, with its sources`

---

### Task 9: Today — "From your routines"

**Files:**
- Create: `mobile/lib/widgets/routine_sections.dart`
- Modify: `mobile/lib/screens/home_screen.dart`
- Test: `mobile/test/widgets/routine_sections_test.dart`, `mobile/test/screens/today_screen_test.dart`

**Interfaces:**
- Consumes: Tasks 6–8.
- Produces: `final class RoutinesTodayPanel extends StatelessWidget { required List<RoutineRun> runs; required void Function(RoutineRun) onOpen; }` (`Key('routines-today')`): title **From your routines**; one row per `reported` / `failed` run, newest first: `ExpandableText` is **not** used here — the row shows the start of the text in 2 lines and opens the sheet on tap (the sheet is the page behind it); below it `'{instruction} · {time}'`; failed rows say **Could not run** in `palette.red`. Then one muted line for quiet ones: `'1 checked, nothing new'` / `'{n} checked, nothing new'` (`nothing` only), and one per `skipped` run: `"Missed at {time}: Echo's server was off"`. Returns `SizedBox.shrink()` when `runs` is empty.
- Today: loads `listRoutineRuns(since: start of today, local)` in `_refreshAll` and when `routineRunsChanged` changes; the panel goes right after the top card, before `TodoPanel`, only when today has runs. "Ask about this" calls `askAboutRoutineRun(run.id)` then `appController.requestOpenThread()`; an error shows a SnackBar `'Could not open it in Ask.'`.

- [ ] **Step 1: Write the failing tests** — `today panel lists reported and failed runs and counts quiet ones`; `today panel with only quiet runs shows one muted line` (no rows, text `'2 checked, nothing new'`); a tap opens the sheet; Today without runs has no `routines-today`; Today with a run puts the panel above "To do today".
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `flutter analyze && flutter test` → PASS.
- [ ] **Step 5: Commit** — `feat(mobile): Today shows what your routines found`

---

### Task 10: Ask — Chat | Routines

**Files:**
- Create: `mobile/lib/screens/routine_runs_view.dart`
- Modify: `mobile/lib/screens/chat_screen.dart` (and where `ChatScreen` is built, to pass `appController.askView` / `routinesFilter` / `routineRunsChanged`)
- Test: `mobile/test/screens/routine_runs_view_test.dart`, `mobile/test/screens/chat_screen_test.dart`

**Interfaces:**
- Consumes: Tasks 6–8; `AskView`, `routinesFilter`, `routineRunsChanged`, `requestOpenThread` (Task 7).
- Produces:
  - `ChatScreen` gains `ValueNotifier<AskView>? askView`, `ValueNotifier<String?>? routinesFilter`, `ValueListenable<int>? routineRunsChanged`, `RoutinesApi? routinesApi`. Under the header a two-way `SegmentedButton<AskView>` (`Key('ask-view')`, labels **Chat** / **Routines**); Chat is today's screen unchanged; Routines shows `RoutineRunsView`. The history and new-chat header buttons show only in Chat.
  - `final class RoutineRunsView extends StatefulWidget { required RoutinesApi api; String? routineId; required ValueChanged<String?> onFilter; required Future<void> Function(RoutineRun) onAskAbout; ValueListenable<int>? changes; }` — chips **All** + one per routine (from `listRoutines`), the selected one from `routineId`; runs grouped under a day label (`dayLabel`), newest first; each `reported`/`failed` run shows its instruction, time and **full** text (no `maxLines`), its sources, and an **Ask about this** text button (`Key('ask-about-<runId>')`); `nothing` runs as one muted line `'{time} · checked, nothing new'`; `skipped` as the missed line. Loads more with `before = nextBefore` at the end of the list. Empty state: `'Your routines' results show up here.'`
  - Ask about this from Routines: `askAboutRoutineRun`, then `askView.value = AskView.chat` and `_controller.openThread()`, composer focused.

- [ ] **Step 1: Write the failing tests** — switching to Routines lists runs by day with full text; a chip filters (`listRoutineRuns` called with that `routineId`); Ask about this switches to Chat and reloads the thread; header buttons hidden in Routines; `askView` set from outside (a notification) shows Routines.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `flutter analyze && flutter test` → PASS.
- [ ] **Step 5: Commit** — `feat(mobile): Ask → Routines, the history of what routines found`

---

### Task 11: Profile → Routines, and the docs

**Files:**
- Modify: `mobile/lib/screens/settings/routines_screen.dart`, `README.md`, `docs/ROADMAP.md`, `docs/PROJECT-STATUS.md`
- Test: `mobile/test/screens/routines_screen_test.dart` (or the existing routines screen test file)

**Interfaces:**
- Consumes: Tasks 6–8; `AppController.requestOpenRoutines` (Task 7).
- Produces: each routine shows `routineModeText(routine.mode)` under its schedule; the last result line (from `lastAnswer`/`lastStatus`, `ExpandableText` stays for the inline preview) gets a **See all results** text button (`Key('routine-results-<id>')`) that calls `requestOpenRoutines(routineId: id)`; tapping the last result opens the sheet for the latest run (`listRoutineRuns(routineId: id, limit: 1)`); status words: `reported` (or old `ok`) the answer, `nothing` `'Checked, nothing new'`, `failed` `'Could not run'`, `skipped` `'Missed while Echo was offline'`.
- Docs: README "Does things on its own" mentions the three modes and Ask → Routines; ROADMAP Fase 7 routine line updated (modes, runs, Today, Ask → Routines; APNs still later); PROJECT-STATUS gets the date and the new state.

- [ ] **Step 1: Write the failing tests** — mode text shown; See all results calls `requestOpenRoutines` with the id; `nothing` status shows `'Checked, nothing new'`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `flutter analyze && flutter test` and `make test-all` → PASS.
- [ ] **Step 5: Commit** — `feat(mobile): routines show their mode and lead to their results; docs`
