# Plans and quotas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each account has a plan (free / plus / unlimited) with a monthly speech budget; past it Echo
transcribes a daily allowance at once and defers the rest without losing it; the app shows the plan,
and web searches and routines follow the plan.

**Architecture:** Plans are configuration in `services/plans.py` (defaults, overridable by `PLANS`
in `.env`), read against `llm_usage` stt seconds for the UTC calendar month. The STT worker decides
per segment under its row lock: transcribe, or mark it `deferred` (status) and keep its audio.
Deferred segments go back through a second, lower-priority queue (`queue:stt:deferred`) filled
hourly by a release loop and at once by `make set-plan`; there they may only use the month's budget,
never the daily allowance. `GET /api/plan` feeds Profile → Plan and a quiet Today line.

**Tech Stack:** FastAPI, SQLAlchemy async, Alembic, Redis, pytest; Flutter (Dart), flutter_test.

**Spec:** docs/superpowers/specs/2026-10-24-plans-and-quotas-design.md

## Global Constraints

- Plans: free 300 min / plus 1 500 min / unlimited 9 000 min a month; 10 min a day after the budget;
  web searches 5 / 30 / 60 a day; routines 2 / 10 / 10.
- `users.plan` default `free`; a key with no account row is on `free`. Unknown plan names read as free.
- Period: calendar month, UTC; resets on the 1st. Usage is `llm_usage` kind `stt` `input_units`
  (seconds), no second counter.
- Deferred audio is never deleted by retention while deferred.
- Deferred speech is transcribed oldest first, at most the month's remaining budget at a time, and
  counts on the month it is transcribed in.
- Migration 025, down_revision "024"; docs/schema.sql and tests/test_migrations.py updated.
- App copy in English only. No purchase in the app.
- Every test/lint/build through the lock scripts, one at a time.

## Review Focus

1. A deferred segment transcribed weeks later must join a conversation at its own time, not the
   latest one (assign_to_conversation today picks the latest) → Task 4 test.
2. A deferred segment that says "Ehi Echo" must not start a voice request when transcribed late → Task 3 test.
3. Released backlog must not eat today's daily allowance, nor delay live speech (separate queue,
   live first) → Task 3 tests.
4. The same deferred segment queued twice (hourly loop + set-plan) is transcribed once → Task 3 test
   (late claim of a non-deferred segment is skipped) and Task 5 (no release while the queue is non-empty).
5. Incomplete-audio retention (7 days) must skip deferred segments → Task 2 test.

---

### Task 1: Plans, the users.plan column and usage

**Files:**
- Create: `backend/app/services/plans.py`, `backend/alembic/versions/025_user_plan.py`, `backend/tests/test_plans.py`
- Modify: `backend/app/models/user.py`, `backend/app/core/config.py`, `docs/schema.sql`, `backend/tests/test_migrations.py`

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) class Plan: name: str; monthly_minutes: int; daily_minutes: int; web_searches_per_day: int; routines: int`
  - `DEFAULT_PLANS: dict[str, dict[str, int]]`, `FREE = "free"`, `plan_names() -> list[str]`, `get_plan(name: str | None) -> Plan`
  - `async user_plan(db, user_id) -> Plan`
  - `month_start(day: date) -> date`, `next_month_start(day: date) -> date`
  - `async speech_seconds(db, user_id, since: date) -> int` (stt input_units, day >= since)
  - `async deferred_seconds(db, user_id) -> int` (sum of `duration_ms` of `deferred` segments // 1000)
  - `async may_transcribe(db, user_id, *, late: bool, today: date | None = None) -> bool`
  - `@dataclass class PlanUsage(plan, used_seconds, deferred_seconds, resets_on)` with `budget_seconds`, `over_budget`
  - `async plan_usage(db, user_id, today=None) -> PlanUsage`
  - `async set_user_plan(db, email: str, plan: str) -> User` (ValueError: unknown plan / no account)
  - `settings.plans: dict[str, dict[str, int]] = {}` (per-plan overrides); `settings.web_searches_per_day` removed
  - `User.plan: Mapped[str]` String(20), server_default 'free'

- [ ] **Step 1: Write failing tests** in `tests/test_plans.py`:
  `test_the_default_plans` (free 300/10/5/2, plus 1500/10/30/10, unlimited 9000/10/60/10),
  `test_an_unknown_plan_is_free`, `test_settings_override_a_plan` (monkeypatch `settings.plans = {"plus": {"monthly_minutes": 600}}` → plus 600, rest default),
  `test_month_bounds` (2026-10-24 → 2026-10-01 / 2026-11-01; 2026-12-31 → 2027-01-01),
  `test_speech_counts_this_month_only` (stt rows on 09-30 and 10-02 and an `llm` row → only 10-02),
  `test_may_transcribe_within_the_budget`, `test_past_the_budget_only_the_daily_allowance` (month used ≥ 300 min: today < 10 min → True, ≥ 10 min → False, late → False),
  `test_a_user_without_account_is_free`, `test_set_user_plan` (sets, rejects "gold" and an unknown email),
  `test_plan_usage` (used, deferred seconds from two deferred segments, resets_on).
  In `test_migrations.py`: the chain to 025 and `test_migration_025_adds_the_user_plan` (column not nullable).
- [ ] **Step 2: Run** `tests/test_plans.py tests/test_migrations.py` (through the lock) → FAIL (no module).
- [ ] **Step 3: Implement** the above; migration `op.add_column("users", sa.Column("plan", sa.String(20), nullable=False, server_default="free"))`; schema.sql line `plan VARCHAR(20) NOT NULL DEFAULT 'free',  -- free | plus | unlimited (025)`.
  `may_transcribe`: month used < budget → True; late → False; today used < daily allowance → True.
- [ ] **Step 4: Run** → PASS. **Step 5: Commit** `feat(server): plans, the user's plan and the month's speech`.

### Task 2: Retention keeps deferred audio

**Files:** Modify `backend/app/workers/retention.py`; Test `backend/tests/test_retention.py`

- [ ] **Step 1:** `test_deferred_audio_is_kept_past_the_incomplete_limit` (a `deferred` segment 30 days old keeps its audio; a `failed` one of the same age is cleared).
- [ ] **Step 2:** run → FAIL. **Step 3:** the incomplete branch also requires `transcription_status != "deferred"`. **Step 4:** PASS. **Step 5:** commit `feat(server): deferred speech keeps its audio`.

### Task 3: The STT worker defers past the budget

**Files:** Modify `backend/app/workers/stt.py`; Test `backend/tests/test_deferred_speech.py`, adapt fakes in `test_worker_pipeline.py`, `test_usage_owner.py`, `test_user_language.py`, `test_voice_requests.py`

**Interfaces:**
- Consumes: `may_transcribe` (Task 1).
- Produces: `DEFERRED_STT_QUEUE = "queue:stt:deferred"`; `_claim_stt_audio(db, redis_client, segment_id, *, late: bool = False)`; `process_stt` pops `[STT_QUEUE, DEFERRED_STT_QUEUE]` (live first) and treats items from the second as late.

- [ ] **Step 1:** tests (real DB, a segment row, audio file in tmp_path):
  `test_past_the_budget_a_segment_is_deferred` (status `deferred`, audio kept, no transcription, nothing queued),
  `test_within_the_allowance_it_is_transcribed`,
  `test_a_late_segment_skips_the_daily_allowance` (claim with late=True past budget, today < allowance → stays deferred),
  `test_a_late_claim_of_a_done_segment_is_skipped` (status completed, late → None, status unchanged),
  `test_late_speech_starts_no_voice_request` (process_stt on the deferred queue with "Echo, …" text → analysis queued, no voice).
- [ ] **Step 2:** FAIL. **Step 3:** implement; CancelledError requeues to the queue it came from. **Step 4:** PASS (and the adapted older STT tests).
- [ ] **Step 5:** commit `feat(server): past the budget, speech waits as deferred`.

### Task 4: Late speech joins a conversation at its own time

**Files:** Modify `backend/app/services/analysis_pipeline.py` (`assign_to_conversation`); Test `backend/tests/test_conversation_segmentation.py`

- [ ] **Step 1:** `test_late_speech_joins_the_conversation_of_its_time` (conversations at 09:00–09:30 and 15:00–15:10; a segment at 09:20 joins the first; one at 12:00 opens a new one; one at 15:05 still joins the latest).
- [ ] **Step 2:** FAIL. **Step 3:** when the segment is older than the latest conversation's start by at least the silence timeout, compare against the latest conversation started at or before the segment instead. **Step 4:** PASS. **Step 5:** commit `fix(server): late speech joins the conversation of its time`.

### Task 5: Releasing deferred speech (hourly, and when the plan changes) and make set-plan

**Files:** Create `backend/app/workers/deferred.py`, Test `backend/tests/test_deferred_release.py`; Modify `backend/app/workers/main.py`, `backend/app/cli/users.py`, `Makefile`

**Interfaces:**
- Produces: `async release_deferred(redis_client, *, session_factory=async_session, user_id=None, today=None) -> int` (segments queued); `RELEASE_INTERVAL_S = 3600`; `run_deferred_loop(redis_client, shutdown_event)`; CLI `python -m app.cli.users set-plan --email E --plan P` (no password asked; releases that user's deferred speech).

- [ ] **Step 1:** tests: `test_release_queues_the_oldest_within_the_budget` (budget left 60 s, three 40 s deferred segments → the two oldest, oldest first in pop order),
  `test_no_release_past_the_budget`, `test_no_release_while_the_queue_holds_some`, `test_release_for_one_user`,
  `test_set_plan_cli_sets_and_releases` (calls `_main` with a fake redis), `test_worker_main_starts_the_deferred_loop`.
- [ ] **Step 2:** FAIL. **Step 3:** implement; Makefile `set-plan: ## Set an account's plan (free, plus, unlimited): make set-plan EMAIL=you@example.com PLAN=plus`. **Step 4:** PASS. **Step 5:** commit `feat(server): deferred speech is released when the budget allows; make set-plan`.

### Task 6: Web searches and routines follow the plan

**Files:** Modify `backend/app/services/web_search.py`, `backend/app/actions/routine_tools.py`, `backend/app/services/routines.py` (drop `MAX_ROUTINES`), `.env.example`, `README.md`; Tests `test_web_search.py`, `test_web_answers.py`, `test_routines_agent.py`

- [ ] **Step 1:** `test_the_cap_is_the_plans` (free user: 5 searches → no tool; set plan plus → tool again), routine test: free allows 2 then refuses with "At most 2 routines on your plan"; plus allows 10.
- [ ] **Step 2:** FAIL. **Step 3:** implement (the plan is read in the same session as the count). **Step 4:** PASS. **Step 5:** commit `feat(server): web searches and routines by plan`.

### Task 7: GET /api/plan

**Files:** Create `backend/app/routers/plan.py`, Test `backend/tests/test_plan_api.py`; Modify `backend/app/main.py`

Response: `{"plan", "monthly_seconds", "used_seconds", "daily_seconds", "deferred_seconds", "resets_on" (ISO date), "over_budget", "web_searches_per_day", "routines"}`.

- [ ] Tests `test_the_plan_and_its_use`, `test_a_key_without_account_is_free`, `test_needs_a_key`; FAIL; implement; PASS; commit `feat(server): GET /api/plan`.

### Task 8: App — the plan model, API and Profile → Plan

**Files:** Create `mobile/lib/models/plan.dart`, `mobile/lib/services/api/plan_api.dart`, `mobile/lib/screens/settings/plan_screen.dart`, `mobile/test/models/plan_test.dart`, `mobile/test/screens/plan_screen_test.dart`; Modify `mobile/lib/services/api/api_service.dart`, `mobile/lib/utils/formatting.dart`, `mobile/lib/screens/profile_screen.dart`, `mobile/test/screens/profile_screen_test.dart`

**Interfaces:**
- `final class PlanInfo` (`plan`, `monthlySeconds`, `usedSeconds`, `dailySeconds`, `deferredSeconds`, `resetsOn`, `overBudget`, `webSearchesPerDay`, `routines`; `fromJson`; `name` "Free"; `nearBudget` ≥ 80 %);
  `abstract interface class PlanApi { Future<PlanInfo> getPlan(); }`, `mixin PlanEndpoints`;
  `String speechAmount(int seconds)` ("40 min", "2.5 h", "25 h"); `String dayAndMonth(DateTime)` ("1 November").
- Copy: Profile row "Plan", value "Free", subtitle "12 h of 25 h this month". Plan screen: the name,
  "12 h of 25 h this month", bar, "Starts again on 1 November.", over budget: "This month's speech is
  used. Echo is transcribing 10 minutes a day until 1 November.", waiting: "3 h of speech waiting:
  Echo transcribes it from 1 November.", PAST THE BUDGET explanation, THIS PLAN rows (Speech "25 h a
  month", Web searches "30 a day", Routines "Up to 10"), footer "Plans cannot be changed in the app yet."

- [ ] Tests first (model parsing and formatting; screen copy in the three states; Profile row in order after Echo, absent when the plan cannot load), FAIL, implement, PASS, commit `feat(mobile): Profile → Plan`.

### Task 9: App — the quiet Today line

**Files:** Modify `mobile/lib/screens/home_screen.dart`, `mobile/lib/widgets/today_sections.dart` (`PlanLine`); Test `mobile/test/screens/today_screen_test.dart`

- Over budget: "Echo is transcribing 10 minutes a day until 1 November."; near (≥ 80 %): "4.2 h of this month's 5 h of speech used."; otherwise nothing. A tap opens the Plan screen.
- [ ] Tests first (over, near, under → nothing, tap opens Plan), FAIL, implement, PASS, commit `feat(mobile): Today says when the speech budget is reached`.

### Task 10: Final verification

- [ ] `git merge main`; whole backend suite (echo_test and the private database), ruff, flutter analyze, flutter test, iOS build — one at a time through the lock.
