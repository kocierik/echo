# Places Visited Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in Profile → Places visited that records the phone's stays (≥ 10 min: arrived, left, where, address, name), shows the place of the conversations held there, answers place questions from visits and conversations together, and lets the user delete one, a day or all (kept 90 days, never through MCP).

**Architecture:** One new table `place_visits` (migration 024) and a service `services/places.py` (no model calls): upsert from the phone by a phone-made `key`, the join visit ↔ conversation worked out at read time (time overlap, no column on `conversations`), the "Places visited" context lines and the 90-day cleanup. A router `/api/places` takes batched uploads and serves the list and the deletes; conversation list/detail items gain `place`. Memory retrieval adds a "Places visited" section and the place of each summarised conversation, both left out with `include_places=False` (MCP). On the phone a `PlacesVisitedService` holds the on/off choice, an outbox uploaded under the network policy and a `VisitSource`: on iOS a Swift `VisitRecorder` (CLLocationManager visits, "Always", names from MapKit POI / CLGeocoder) on the `echo/visits` channel; on Android the geolocator stream at balanced power from the process kept alive by `EchoStatusService`, made into stays by a pure Dart `StayDetector`.

**Tech Stack:** FastAPI, SQLAlchemy async, Postgres; Flutter, geolocator, geocoding, shared_preferences; Swift (CoreLocation, MapKit).

**Spec:** `docs/superpowers/specs/2026-10-24-places-visited-design.md`; Saved's location and MCP switch from `2026-10-23-saved-design.md`; tabs from `2026-10-22-app-tabs-redesign-design.md`.

## Global Constraints

- Off by default; nothing records unless on; off stops the source at once and drops the unsent visits; an explicit screen before asking "Always".
- A visit counts from 10 minutes in one place (`MIN_VISIT = 10 min`, phone and server); vague fixes are not visits (accuracy worse than 300 m dropped).
- 90 days kept (`KEEP_DAYS = 90`), then deleted by the worker.
- Name: on iPhone Apple's (MapKit POI near the visit, else CLGeocoder's placemark name when it is not the street) else the address; Android the geocoder's address.
- Uploads batched, any network unless the user chose Wi-Fi only (`NetworkPolicy.canUpload`).
- Never through MCP: `include_places=False` drops the section and the "at …" of conversations.
- Migration 024, `down_revision = "023"`; `docs/schema.sql` and `tests/test_migrations.py` updated; no column on an existing table.
- App copy English only; the AI answers in the user's language.
- Every test/analyze/build through the lock scripts, one at a time; commits `feat(server|mobile): …` ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. The same stay sent twice (iOS arrival then departure; Android open then closed; a retried batch) must stay one visit → `test_the_same_key_updates_the_visit` (Task 2).
2. A stay that ends under 10 minutes after being sent open must disappear → `test_a_stay_closed_under_ten_minutes_is_dropped` (Task 2).
3. One noisy far fix while sitting still must not split a stay → `stay detector: one far point does not end the stay` (Task 7).
4. Turning the option off while visits wait in the outbox must not upload them later → `turning off drops the outbox and stops the source` (Task 8).
5. Outside assistants must never see a place, neither in the section nor in a conversation's summary → `test_mcp_sees_no_places` (Task 4).

---

### Task 1: Table, model, migration 024

**Files:** Create `backend/app/models/place_visit.py`, `backend/alembic/versions/024_place_visits.py`; Modify `backend/app/models/__init__.py`, `docs/schema.sql`, `backend/tests/test_migrations.py`, `backend/tests/conftest.py`.

**Produces:** `PlaceVisit(user_id, key: str(80), arrived_at, left_at|None, latitude: float, longitude: float, accuracy_m: float|None, name: Text|None, address: Text|None, source: str(10) "ios"|"android", created_at, updated_at)`; indexes `ix_place_visits_user_key` unique (user_id, key), `ix_place_visits_user_arrived` (user_id, arrived_at).

- [ ] Test: chain range to 25; `test_migration_024_creates_the_place_visits` (one create_table, both indexes, unique key index, `left_at` nullable).
- [ ] Run → FAIL; implement; run → PASS; conftest `DELETE FROM place_visits`; commit `feat(server): places visited table (migration 024)`.

### Task 2: The places service

**Files:** Create `backend/app/services/places.py`, `backend/tests/test_places_service.py`.

**Produces (flush, never commit unless said):**
- `MIN_VISIT = timedelta(minutes=10)`, `KEEP_DAYS = 90`, `MAX_ACCURACY_M = 300`.
- `async record_visits(db, user_id, visits: list[dict], source: str, now) -> tuple[int, int]` (kept, dropped): validates coordinates (`valid_place`), drops accuracy > 300, left < arrived, arrived older than 90 days or in the future; closed and shorter than 10 min → deletes the stored one with that key; else upserts by key.
- `def counts(visit, now) -> bool` — closed ≥ 10 min, or open and arrived ≥ 10 min ago.
- `async visits_between(db, user_id, start, end, now) -> list[PlaceVisit]` — counting visits overlapping [start, end), oldest first.
- `async places_of(db, user_id, spans: list[tuple[id, start, end]], now) -> dict[id, PlaceVisit]` — per conversation the counting visit with the largest overlap, kept when the overlap is at least half the conversation (a conversation under a minute: its start inside the visit).
- `def label(visit) -> str|None` (name else address), `def place_out(visit) -> dict` `{"visit_id","name","address"}`.
- `async delete_visit / delete_day(db, user_id, day) -> int / delete_all(db, user_id) -> int`.
- `async expire_visits(db, now) -> int` (commits).

- [ ] Tests: create; `test_the_same_key_updates_the_visit`; `test_a_stay_closed_under_ten_minutes_is_dropped`; bad coordinates/accuracy/old dropped; open visit counts only after 10 min; `places_of` picks the larger overlap and ignores a visit covering under half; delete day uses the user's zone; expire older than 90 days only; another user's visits untouched.
- [ ] FAIL → implement → PASS → commit `feat(server): the places service: visits, their conversations, cleanup`.

### Task 3: API, conversations' place, cleanup worker

**Files:** Create `backend/app/routers/places.py`, `backend/app/workers/places.py`, `backend/tests/test_places_api.py`; Modify `backend/app/main.py`, `backend/app/workers/main.py`, `backend/app/routers/conversations.py`.

**Produces:**
- `POST /api/places/visits` `{"visits": [{key, arrived_at, left_at, latitude, longitude, accuracy_m, name, address}], "source"}` (≤ 200) → `{"kept", "dropped"}`.
- `GET /api/places/visits?before=&limit=100` → `{"visits": [{id, arrived_at, left_at, latitude, longitude, name, address, conversations: [{id, title}]}], "more": bool}` newest first, counting only.
- `DELETE /api/places/visits/{id}` 204 (404 for another's); `DELETE /api/places/days/{YYYY-MM-DD}` → `{"deleted"}`; `DELETE /api/places/visits` → `{"deleted"}`.
- `ConversationListItem.place: dict|None` and `ConversationDetail.place` from `places_of`.
- `workers/places.run_places_cleanup_loop(shutdown_event)` every 6 h → `expire_visits`.
- [ ] Tests per endpoint; conversation list/detail carry the place; MCP `get_conversation`/`get_day` results carry no place; cleanup function. FAIL → implement → PASS → commit `feat(server): the places API and the 90-day cleanup`.

### Task 4: Memory answers know places

**Files:** Modify `backend/app/services/memory_retrieval.py`, `backend/app/services/memory_answers.py`, `backend/app/actions/availability.py`, `backend/app/services/about_echo.py`; Test `backend/tests/test_places_retrieval.py`.

- Section "Places visited (from the phone; each a stay of 10 minutes or more):" — with a period: its visits ("- Saturday 17/10/2026 19:55–23:10: Pizzeria Da Gino (Via Garibaldi 5, Milano)", cap 30); without: when the question names a word of a place or asks where/when-went (`_PLACE_QUESTION` regex, it+en), the distinct places of the last 90 days, latest first, with last visit and count (cap 25). Summary lines and "Mentioned in" carry " (at <label>)". Nothing of this with `include_places=False`. Only places → context not empty.
- Prompt: describe the section; intent prompt: where the user was is memory; about Echo: a line for Profile → Places visited.
- [ ] Tests: a period lists its visits; "quando sono andato in palestra" lists places; a conversation summary carries its place; `test_mcp_sees_no_places`; failure of the places query leaves the answer working. FAIL → implement → PASS → commit `feat(server): memory answers know the places visited`.

### Task 5: Evals

**Files:** Modify `backend/evals/cases/answers.json`, `backend/evals/cases/routing.json`.
- answers context gains places and summaries with "(at …)"; cases: Saturday evening → gino; last gym → 16; lunch with Ada (en) → treno; cinema this week → a no.
- routing: place questions (it/en, one with camera) → memory; "salvami questo posto" → agent.
- [ ] Run each suite at most a few times through serial.sh; prompt fixes never with a case's sentence; commit `feat(server): places in the evals`.

### Task 6: App models and API

**Files:** Create `mobile/lib/models/place.dart`, `mobile/lib/services/api/places_api.dart`; Modify `mobile/lib/models/memory.dart`, `mobile/lib/services/api/api_service.dart`; Tests `mobile/test/models/place_test.dart`, `mobile/test/services/api/places_api_test.dart`.

**Produces:** `ConversationPlace(visitId, name, address)` with `label`; `ConversationCard.place`; `RecordedVisit(key, arrivedAt, leftAt, latitude, longitude, accuracyM, name, address)` with `toJson/fromJson`; `PlaceVisit(id, arrivedAt, leftAt, name, address, conversations: List<(String id, String? title)>)` with `label`; `VisitPage(visits, more)`; `abstract interface class PlacesApi { postVisits(List<RecordedVisit>, {required String source}); listVisits({DateTime? before}); deleteVisit(id); deleteVisitDay(DateTime day); deleteAllVisits(); }` + `PlacesEndpoints`.
- [ ] Tests, FAIL, implement, PASS, commit `feat(mobile): places models and API`.

### Task 7: Stays and the visit sources

**Files:** Create `mobile/lib/services/phone/stay_detector.dart`, `mobile/lib/services/phone/visit_sources.dart`; Test `mobile/test/services/phone/stay_detector_test.dart`, `visit_sources_test.dart`.

- `StayDetector({radiusM = 150, minStay = 10 min, maxAccuracyM = 300})`, `List<RecordedVisit> add(Fix)`: a fix within the radius of the stay's centre extends it (centre a running mean); one far fix is held; a second far fix ends the stay (left = last fix inside) and starts a new one from the held fix; a held fix followed by one inside is discarded; a stay emits once open when it reaches 10 min and once closed; `toJson/fromJson` to survive a restart. Key `android:<arrived ms>`.
- `enum VisitAccess { always, whileInUse, denied, notAsked, off }`; `abstract interface class VisitSource { access(); requestAlways(); start(onVisits); stop(); }`.
- `IosVisitSource` over `echo/visits` (`access`, `requestAlways`, `start`, `stop`, `take` → list of maps; Dart is told "visits" by the native side and calls `take`).
- `AndroidStaySource(reader stream, geocode, store)`: geolocator `getPositionStream(AndroidSettings(accuracy: medium (balanced), intervalDuration: 3 min, distanceFilter: 0))`, fixes into the detector, closed/open stays geocoded (address) then handed on.
- [ ] Tests for the detector (stay, short stop, noisy point, restart) and the iOS mapping with a mock channel. FAIL → implement → PASS → commit `feat(mobile): stays from the phone's visits`.

### Task 8: The Places visited service

**Files:** Create `mobile/lib/services/phone/places_visited.dart`; Modify `mobile/lib/services/app/app_lifecycle_coordinator.dart`; Test `mobile/test/services/phone/places_visited_test.dart`.

- `PlacesVisitedService(source, api: PlacesApi, preferences, networkAccess, networkPolicy, sourceName)`: `isOn`; `resume()` (on at start → `source.start`); `turnOn() -> VisitAccess` (asks Always; on only with always); `turnOff()` (stop, outbox and detector state cleared, pref false); visits → outbox (merged by key) → `flush()` when the policy allows (batches of 50, removed on success, kept on failure); flush on wake.
- [ ] Tests: off by default and nothing starts; turn on without Always stays off; visits uploaded and removed; Wi-Fi only on mobile data keeps them; `turning off drops the outbox and stops the source`; a failed upload keeps them. FAIL → implement → PASS → commit `feat(mobile): the Places visited service`.

### Task 9: Native iOS and Android

**Files:** Create `mobile/ios/Runner/Visits/VisitRecorder.swift`; Modify `mobile/ios/Runner/AppDelegate.swift`, `mobile/ios/Runner.xcodeproj/project.pbxproj`, `mobile/ios/Runner/Info.plist` (`NSLocationAlwaysAndWhenInUseUsageDescription`, `NSLocationWhenInUseUsageDescription` text covering both; no `location` background mode), `mobile/android/app/src/main/AndroidManifest.xml` (`ACCESS_BACKGROUND_LOCATION`).
- Recorder made in `didFinishLaunching` (a relaunch for a visit has no Flutter engine), pending visits in UserDefaults until taken, monitoring resumed when the stored flag is on; naming in a background task with a 20 s cap.
- [ ] Verified by the iOS build at the end; commit `feat(mobile): visits from iOS, background location on Android`.

### Task 10: Profile → Places visited, places on conversations

**Files:** Create `mobile/lib/screens/settings/places_visited_screen.dart`; Modify `mobile/lib/screens/profile_screen.dart`, `mobile/lib/widgets/conversation_card.dart`, `mobile/lib/widgets/today_sections.dart`, `mobile/lib/screens/conversation_detail_screen.dart`; Tests `mobile/test/screens/places_visited_screen_test.dart`, additions to `today_screen_test.dart`, `conversation_detail_screen_test.dart`, `profile_screen_test.dart`.
- Screen: off → what is kept and "Turn on" → the opt-in explanation → `turnOn`; refused Always → message and "Open Settings"; on → switch, visits by day (time range, label, conversations), delete one (confirm), "Delete day", "Delete all places"; turning off asks "Also delete the places Echo kept?".
- Cards, Your day and the conversation page show the place label.
- [ ] Tests, FAIL, implement, PASS, commit `feat(mobile): Profile → Places visited, and the place of a conversation`.

### Task 11: Merge main and verify

- [ ] `git merge main`; then one at a time: backend suite, ruff, flutter analyze, flutter test, `flutter build ios --debug --no-codesign`; fix and commit; report.
