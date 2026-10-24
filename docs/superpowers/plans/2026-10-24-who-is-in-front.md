# Who Is In Front Of You Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a freshly transcribed segment's voice confidently matches a known person and the stored facts give something worth saying, the phone shows it at once ("Talking with Marco Rossi — You promised: the quote · last talked Oct 22: Atlas launch"), opening the person's page on tap.

**Architecture:** No migration, no model call. A Redis "notice ledger" (`services/notice_ledger.py`) remembers per user and local day what the phone was given (the scheduled notices handed out by `/notifications/upcoming`, and the briefs sent at once), so the three-a-day limit counts both, a meeting briefing for a person is known when a voice of theirs arrives, and the briefings switch the app sent last is known to the server. `services/person_brief.py` runs after the STT worker commits a live segment whose voice matched a named person: rules, then `_what_to_know` (extended with what the person promised the user), then a `person_brief` device command valid 120 s. The app parses it, and `PersonBriefs` shows it as a local notification (payload `person:<id>`) when the briefings switch is on.

**Tech Stack:** FastAPI, SQLAlchemy async, Redis (redis.asyncio); Flutter, flutter_local_notifications, shared_preferences.

**Spec:** `docs/superpowers/specs/2026-10-24-who-is-in-front-design.md`.

## Global Constraints

- Only the confident threshold (`voice_match == "auto"`, i.e. `settings.voice_match_threshold`), never the "Marco?" suggestion; never the user's own profile.
- Nothing to say (`_what_to_know` empty) → no notification.
- At most once per person every 4 hours (`PERSON_EVERY = timedelta(hours=4)`, Redis `SET NX EX`).
- Skipped when a calendar briefing for that person fires within 1 hour (`NEAR_BRIEFING = timedelta(hours=1)`), before or after.
- Briefings switch, quiet hours 22–8 (`is_quiet`), `MAX_PER_DAY = 3` in total with the scheduled notices.
- Command `person_brief` `{person_id, title, body}`, `ttl_s = 120` (dropped when not taken in 2 minutes); only live speech (not `queue:stt:deferred`, recorded at most 10 minutes ago).
- App copy English only. Commits `feat(server|mobile): …` ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Every test/analyze through the lock scripts, one at a time.

## Review Focus

1. Two segments of Marco a second apart must give one notification → `test_once_per_person_every_four_hours` (Task 3).
2. Speech uploaded late from the wearable's backlog (recorded an hour ago) must not brief now → `test_late_speech_is_not_briefed` (Task 3).
3. A profile named by the user but without a person entity (`person_id` None) still finds the person by name → `test_a_voice_without_person_link_finds_the_person_by_name` (Task 3).
4. Redis or DB trouble in the brief must never fail the transcription → `test_a_failing_brief_does_not_fail_the_transcription` (Task 4).
5. Each refresh of the scheduled notices must not count the same notice twice nor keep a dropped future one → `test_refresh_replaces_future_entries` (Task 2).

---

### Task 1: `_what_to_know` says what the person promised the user

**Files:** Modify `backend/app/services/notifications.py`, `backend/tests/test_notifications.py`.

**Produces:** `_what_to_know(db, user_id, person, promises, now, waiting: Sequence[Entity] = ()) -> list[str]` adds `"they promised: <name>"` (first open "expected" task whose `expected_from` names the person) right after "you promised"; those tasks are not counted again in "N open tasks". `briefing_notices(..., waiting=None)` and `upcoming_notices` pass `open_waiting(...)` when briefings are asked for. `select_notices(notices, now, until, taken: dict[date, int] | None = None)`: `taken` notices already given that day count towards `MAX_PER_DAY`; `upcoming_notices(..., taken=None)` passes it through.

- [ ] Tests: `test_a_briefing_says_what_the_person_promised` (a person with only an expected task from them gets a briefing whose body contains `they promised: Preventivo da Marco` and no "open task"); `test_notices_already_given_today_count_towards_three` (`select_notices` with `taken={TODAY: 2}` keeps one notice that day, three the next).
- [ ] Run → FAIL; implement; run `tests/test_notifications.py` → PASS; commit `feat(server): briefings say what the person promised you`.

### Task 2: The notice ledger and the endpoint recording into it

**Files:** Create `backend/app/services/notice_ledger.py`, `backend/tests/test_notice_ledger.py`; Modify `backend/app/routers/notifications.py`, `backend/tests/test_notifications.py`.

**Produces (all take the redis client first):**
- `DAY_KEY = "notify:day:{user_id}:{day}"` (hash: notice key → JSON `{"kind","fire_at","target"}`, TTL `DAY_TTL_S = 3 days`), `BRIEFINGS_OFF_KEY = "notify:briefings-off:{user_id}"`.
- `async record_scheduled(redis, user_id, notices: list[Notice], now, until) -> None` — drops the entries firing in (now, until], then adds `notices` to their local days.
- `async record_sent(redis, user_id, key: str, kind: str, target: str, now) -> None`.
- `async given_per_day(redis, user_id, now, until) -> dict[date, int]` — per local day in [now, until], entries with `fire_at <= now`.
- `async count_on(redis, user_id, day: date) -> int` — every entry of that day (fired, sent or still scheduled).
- `async briefing_near(redis, user_id, target: str, now, within: timedelta) -> bool` — a `briefing` entry for `target` firing within `within` of `now`.
- `async set_briefings(redis, user_id, on: bool)`, `async briefings_on(redis, user_id) -> bool` (default on).
- Router: `_upcoming(db, redis, user_id, request)` takes `taken = given_per_day(...)` before, then `record_scheduled` and `set_briefings(request.briefings)`; ledger errors are logged, never fail the endpoint.

- [ ] Tests: `test_refresh_replaces_future_entries` (record A,B; then record only B: today counts B + fired ones, not A; a fired entry stays); `test_briefing_near_looks_an_hour_either_side`; `test_briefings_switch_is_remembered`; `test_the_endpoint_records_what_it_hands_out` (GET upcoming with a promise tomorrow → `count_on(tomorrow) == 1`; `?briefings=false` → `briefings_on` False).
- [ ] FAIL → implement → PASS → commit `feat(server): the notice ledger: what the phone was given each day`.

### Task 3: The person brief

**Files:** Create `backend/app/services/person_brief.py`, `backend/tests/test_person_brief.py`; Modify `backend/app/services/device_commands.py` (docstring kinds).

**Consumes:** Task 1 `_what_to_know`, `open_promises`, `open_waiting`, `is_quiet`, `MAX_PER_DAY`; Task 2 ledger; `push_device_command`; `voice_profiles._person_named`.

**Produces:**
- `PERSON_EVERY`, `NEAR_BRIEFING`, `COMMAND_TTL_S = 120`, `LIVE_WITHIN = timedelta(minutes=10)`, `COOLDOWN_KEY = "notify:person:{user_id}:{person_id}"`.
- `def confident_voice(segment, profiles) -> VoiceProfile | None` — the profile of an `auto` match that is not the user's own.
- `async brief_who_is_talking(db, redis, segment, profile, now=None) -> dict | None` — the command pushed, or None. Order: live (`now - recorded_at <= LIVE_WITHIN`), not quiet, briefings on, person found (`person_id` else by name), no briefing near, `count_on(today) < MAX_PER_DAY`, facts, then cooldown `SET NX`; push `{"type": "person_brief", "person_id", "title": "Talking with <name>", "body": <facts joined " · ", first letter upper>}`, `record_sent(key="person:<id>:<iso>", kind="person")`.

- [ ] Tests: `test_confident_voice_only`; `test_a_known_voice_with_something_to_say_is_briefed` (command fields, ttl ≤ 120 s, ledger +1); `test_nothing_to_say_no_brief`; `test_once_per_person_every_four_hours`; `test_late_speech_is_not_briefed`; `test_quiet_hours_switch_off_and_three_a_day`; `test_not_within_an_hour_of_a_meeting_briefing`; `test_a_voice_without_person_link_finds_the_person_by_name`.
- [ ] FAIL → implement → PASS → commit `feat(server): who is in front of you: a brief when a known voice speaks`.

### Task 4: The STT worker runs the brief

**Files:** Modify `backend/app/workers/stt.py`, `backend/tests/test_person_brief.py`.

**Produces:** after the commit, for live segments only, `await _brief_known_voice(db, redis_client, segment, known)` (known = `confident_voice(segment, profiles)`), catching and logging any error.

- [ ] Tests (run `process_stt` with monkeypatched collaborators as in `test_deferred_speech.py`): `test_the_worker_briefs_a_known_voice` (brief called with the matched profile), `test_deferred_speech_is_not_briefed`, `test_a_failing_brief_does_not_fail_the_transcription` (status stays `completed`, analysis queued).
- [ ] FAIL → implement → PASS → commit `feat(server): the STT worker briefs who is talking`.

### Task 5: The app shows it

**Files:** Modify `mobile/lib/models/device_command.dart`, `mobile/lib/services/device/device_command_loop.dart`, `mobile/lib/services/app/notification_service.dart`, `mobile/lib/services/app/notification_scheduler.dart`, `mobile/lib/services/app/app_lifecycle_coordinator.dart`; Test `mobile/test/services/device/device_command_loop_test.dart`, `mobile/test/services/app/notification_service_test.dart`.

**Produces:** `PersonBriefCommand({personId, title, body})` from `{"type": "person_brief", ...}` (all three strings, else null); loop `onPersonBrief` (not awaited); `NotificationService.showPersonBrief({personId, title, body})` on ids `personBriefBaseId = 400`… (10, rotating), payload `person:<id>`; `PersonBriefs(notifications, preferences).show(command)` shows only with `preferences.briefings`.

- [ ] Tests: parse (valid, missing body → null); loop hands it to its handler; `showPersonBrief` id/payload, two people get two ids; `PersonBriefs` drops it with briefings off.
- [ ] FAIL → implement → PASS; `flutter analyze` clean; commit `feat(mobile): who is in front of you, shown at once`.

### Task 6: Seen in the app and the docs

**Files:** Modify `mobile/lib/screens/settings/notification_settings_screen.dart`, `mobile/lib/screens/settings/capabilities_screen.dart`, `mobile/test/screens/notification_settings_test.dart`, `README.md`, `docs/PROJECT-STATUS.md`.

**Produces:** the briefings switch row titled "Briefings" naming both: "Before a meeting …" and "When someone you know starts talking: …, at most once every 4 hours"; What Echo can do: a "Who is in front of you" row and "Comes to you, rarely" naming it; README feature line and the `person_brief` command.

- [ ] Test: `find.textContaining('When someone you know starts talking')` in the settings; capabilities shows "Who is in front of you".
- [ ] FAIL → implement → PASS → commit `feat(mobile): notification settings and What Echo can do name who is in front of you`.
