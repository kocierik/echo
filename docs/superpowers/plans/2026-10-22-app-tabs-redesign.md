# App tabs redesign: Today, Ask, Profile — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tabs become Today · Ask · Profile; Ask is one thread with Echo (typed, voice, photo and
routine answers); photo answers are large with quick follow-ups; voice requests about what the
user is looking at reach the camera; Today gets one adaptive top card and Memories' content;
Profile holds every setting; a new "Echo" device screen; a nullable `users.name`.

**Architecture:** The per-user voice session (`ChatSession.kind == "voice"`) becomes "the thread":
a new `GET /api/chat-sessions/thread` returns it (created on first use), messages carry a
`source` ("voice", "chat", "camera"), and the query path reads a persisted session's history
from Postgres (the voice worker and photos write only there), so typed and voice turns share one
context without double entries. Photo follow-ups re-ask the vision model on the stored image
(`POST /api/photos/{id}/ask`). In the app, `ChatController` opens the thread by default, Today
reuses `MemoriesController` (search, people, days) and picks one top card with a pure function,
and Profile is the old Settings screen regrouped.

**Tech Stack:** FastAPI, SQLAlchemy async, Alembic, pytest; Flutter (Dart 3), flutter_test.

**Spec:** `docs/superpowers/specs/2026-10-22-app-tabs-redesign-design.md`

## Global Constraints

- App UI copy in English only; the AI answers in the user's language.
- Tabs: Today (0) · Ask (1, centre, hold to dictate) · Profile (2). The stored tab under
  `echo_selected_tab_v3` with index 2 (Memories) must open Today, never Profile.
- Migration **021** (`down_revision = "020"`, 020 is the routines table on main): `users.name`
  nullable `VARCHAR(100)`; existing voice sessions get the title "Echo". Update
  `docs/schema.sql` and `tests/test_migrations.py`.
- The thread's title is "Echo"; "New chat" starts a separate typed chat that never receives
  voice, photo or routine messages.
- Only voice requests route to the wearable camera (`camera=True`); in Ask the camera button
  takes the photo and the composer text is its question.
- No intra-day LLM digest: "So far today" is built from today's conversation titles and counts.
- Empty Today sections are hidden, not shown empty. One top card at most.
- Tests and builds one at a time, through the lock scripts (`btwt.sh`, `serial.sh`).
- Reuse: `EchoAppShell`, `EchoNavBar`, `HomeScreen`, `today_sections.dart`, Memories parts,
  `ChatScreen`/`ChatController`, `screens/settings/*`, `DeviceInstrumentPanel`,
  `VoiceUpdatesService`, `get_or_create_voice_session`, `route_request`, `VISION_PROMPT`.

## Review Focus

- A typed question sent while the voice worker writes the thread: both turns kept (row lock in
  `persist_chat_session`) — test in Task 2.
- A thread with old messages that have no `source` or `timestamp` (written before this change):
  loads without error, legacy user messages in the thread read "By voice" — tests in Tasks 2, 8.
- The account has no name (and no own voice): the greeting is "Good afternoon" with no comma,
  and the Name row offers to add one — tests in Tasks 1, 7, 10.
- The vision model returns a malformed or naive `when`: no "Remind me" chip and no crash — tests
  in Tasks 3, 9.
- A phone with no calendar access, or an event later than one hour: no "coming up" card, the next
  case applies — tests in Tasks 5, 10.

---

### Task 1: `users.name` (migration 021) and the thread title

**Files:**
- Create: `backend/alembic/versions/021_user_name.py`
- Modify: `backend/app/models/user.py`, `backend/app/routers/auth.py`, `backend/app/actions/voice.py`
  (`VOICE_SESSION_TITLE = "Echo"`), `docs/schema.sql`
- Test: `backend/tests/test_migrations.py`, `backend/tests/test_user_language.py`

**Interfaces:**
- Produces: `GET/PATCH /api/auth/me` → `{"email", "language", "name"}`; PATCH body
  `{"language"?: "en"|"it", "name"?: str|null}` (blank name → null, max 100 chars).

- [ ] **Step 1: Failing tests:** `test_migration_021_adds_the_user_name_and_names_the_thread_echo`
  (after the whole chain `users.columns["name"] is True`; 021 executes an
  `UPDATE chat_sessions SET title = 'Echo' WHERE kind = 'voice'`);
  `test_me_returns_and_sets_the_name` (new account → `name is None`; PATCH `{"name": " Erik "}` →
  `"Erik"`; PATCH `{"name": ""}` → `None`; PATCH `{"language": "it"}` keeps the name);
  `test_a_new_voice_session_is_titled_echo` (in `test_voice_requests.py`).
- [ ] **Step 2:** Run them: FAIL.
- [ ] **Step 3:** Implement the migration (add column; data update; downgrade drops the column and
  renames back to "Voice requests"), the model column, `Me.name`, `MeUpdate` with optional fields,
  the title constant, schema.sql.
- [ ] **Step 4:** Run `test_migrations.py test_user_language.py test_voice_requests.py`: PASS.
- [ ] **Step 5:** Commit `feat(server): the user's name, and the voice session becomes "Echo"`.

### Task 2: The thread: endpoint, message sources, shared history

**Files:**
- Modify: `backend/app/routers/chat_sessions.py`, `backend/app/services/chat_history.py`,
  `backend/app/routers/query.py`, `backend/app/workers/voice_requests.py`,
  `backend/app/routers/photos.py`
- Test: `backend/tests/test_chat_history_persistence.py`, `backend/tests/test_voice_requests.py`,
  `backend/tests/test_photos.py`

**Interfaces:**
- Produces: `GET /api/chat-sessions/thread` → `ChatSessionDetail` of the voice session (created
  and committed when missing); `ChatSessionDetail.kind`; `ChatMessage` gains `source`,
  `when`, `routine_id`, `about_photo_id` (all optional strings).
- Message `source`: `"voice"` (voice worker user messages, incl. photo requests), `"chat"`
  (`record_turn` user messages), `"camera"` (`POST /photos` user messages).
- `record_turn` stamps both messages with ISO `timestamp`, and the assistant one with
  `"notify": False` (a typed answer is never notified).
- `async def load_thread_history(redis, db, user_id, session_uuid) -> list[dict]`: the persisted
  session's last messages when it exists, else Redis.

- [ ] **Step 1: Failing tests:** `test_thread_endpoint_creates_once_and_returns_the_voice_session`
  (two GETs → same id, title "Echo", kind "voice"); `test_a_typed_question_in_the_thread_sees_voice_turns`
  (thread has a voice turn written directly in Postgres; `/api/query` with its session id passes
  that turn to the LLM as history; afterwards the thread holds voice turn + typed turn, each once,
  the typed user message with `source == "chat"` and the answer with `notify is False`);
  `test_voice_turns_are_marked_by_voice` (worker user message `source == "voice"`, also for a
  photo request); `test_app_camera_question_is_marked_camera`; `test_legacy_messages_without_source_load`.
- [ ] **Step 2:** Run: FAIL.
- [ ] **Step 3:** Implement; `persist_chat_session` selects the row `with_for_update()`.
- [ ] **Step 4:** Run the three test files plus `test_query*.py test_idempotency.py`: PASS.
- [ ] **Step 5:** Commit `feat(server): one thread with Echo for typed and voice requests`.

### Task 3: Photo follow-ups and the photo's date

**Files:**
- Modify: `backend/app/services/photos.py`, `backend/app/routers/photos.py`
- Test: `backend/tests/test_photos.py`

**Interfaces:**
- `VISION_PROMPT` asks for `"when": "<ISO local datetime>" | null` (a date or time worth a
  reminder: a notice, a ticket, an appointment card) and to do what was asked ("explain",
  "translate", "read", "how much") instead of describing.
- `def parse_when(value) -> str | None`: a valid ISO datetime (naive is local) → ISO string, else None.
- The photo's answer message carries `"when"` when set.
- `POST /api/photos/{id}/ask` `{"question": str (1-500)}` → `{"answer": str, "session_id": str}`:
  vision on the stored image with the question (and the first answer as context), appends
  `{"role":"user","content":q,"source":"chat","about_photo_id":id}` and
  `{"role":"assistant","content":a,"about_photo_id":id,"notify":False}` to the photo's chat
  session; 404 for another user's photo or one without an image; 20/minute.

- [ ] **Step 1: Failing tests:** `test_the_answer_keeps_the_date_the_photo_shows`,
  `test_a_bad_when_is_dropped` (`"giovedì"`, `""`, `None` → no `when`),
  `test_a_follow_up_is_answered_from_the_same_image`, `test_follow_up_on_someone_elses_photo_is_404`,
  `test_vision_prompt_does_what_was_asked`.
- [ ] **Step 2:** Run: FAIL. **Step 3:** Implement. **Step 4:** Run `test_photos.py`: PASS.
- [ ] **Step 5:** Commit `feat(server): photo follow-ups, and the date a photo shows`.

### Task 4: Photo requests understood (routing)

**Files:**
- Modify: `backend/app/actions/availability.py` (`CAMERA_SECTION`), `backend/evals/llm.py`
  (routing passes `camera=case.get("camera", False)`), `backend/evals/cases/routing.json`,
  `backend/tests/test_evals.py` (`expect` may be `"photo"`; a photo case needs `"camera": true`)
- Test: `backend/tests/test_evals.py`, `backend/tests/test_voice_requests.py`

- [ ] **Step 1: Failing tests:** `test_camera_prompt_names_tasks_on_what_the_user_sees`
  (the section mentions explain/translate/read examples and that what someone said is memory);
  well-formed check accepts the new cases.
- [ ] **Step 2:** Add cases (camera: true): it "Ehi Echo spiegami cosa c'è scritto qui",
  "cosa c'è scritto qui?", "traducimi il cartello", "quanto costa questo?", "spiegami questo",
  "che pianta è questa?"; en "explain this", "what does this say?", "translate this sign"; negatives
  (expect memory): "spiegami cosa ha detto Marco", "cosa c'era scritto nella mail di Ada di ieri?",
  "traducimi cosa ha detto Luca alla riunione".
- [ ] **Step 3:** Reword `CAMERA_SECTION`. **Step 4:** Run tests: PASS; run the routing eval once
  (real model, `gpt-6-luna`, reasoning none, chat API); record the numbers in the commit message.
- [ ] **Step 5:** Commit `feat(server): voice requests about what the user sees go to the camera`.

### Task 5: Today's data: a photo row's image, and what is coming up

**Files:**
- Modify: `backend/app/routers/conversations.py` (`ConversationListItem.photo_id`: the first photo
  with an image), `backend/app/services/notifications.py`, `backend/app/routers/notifications.py`
- Test: `backend/tests/test_photos.py` or `test_memory_browsing.py`, `backend/tests/test_notifications.py`

**Interfaces:**
- `POST /api/notifications/coming-up` `{"phone_events": [PhoneEvent]}` →
  `{"event": {"title", "start"} | null, "recap": str | null}`: the first event starting within
  the next hour (not all-day); recap "Last time: <title>" of the latest conversation with a person
  the event names, else of the latest conversation whose title contains the event title.

- [ ] **Step 1: Failing tests:** `test_list_items_name_their_first_photo`,
  `test_coming_up_recaps_the_last_talk_with_the_guest`, `test_coming_up_ignores_events_after_an_hour`,
  `test_coming_up_without_a_known_person_uses_the_title`.
- [ ] **Step 2-4:** FAIL, implement, PASS. **Step 5:** Commit `feat(server): Today's photo rows and the next hour's event`.

### Task 6: Tabs Today · Ask · Profile

**Files:**
- Modify: `mobile/lib/widgets/echo_nav_bar.dart` (right destination "Profile",
  `Icons.person_outline_rounded`), `mobile/lib/models/app_view_state.dart`,
  `mobile/lib/services/app/app_controller.dart`, `mobile/lib/main.dart`
- Test: `mobile/test/widgets/app_shell_test.dart`, `mobile/test/services/app/app_controller_test.dart`

**Interfaces:**
- `AppController.selectedTabKey = 'echo_selected_tab_v4'`, `legacySelectedTabKey = 'echo_selected_tab_v3'`
  (read once when v4 is absent: 2 → Today, 0/1 kept), `profileTab = 2` (no `memoriesTab`).
- `AppController.threadUpdates: ValueNotifier<int>` (bumped when voice updates bring new messages).

- [ ] **Step 1: Failing tests:** nav shows Today, Profile and Ask; `an old Memories tab opens Today`;
  `an old Ask tab stays Ask`; the shell's third child is Profile.
- [ ] **Step 2-4:** FAIL, implement (MainShell puts the Settings screen in the third tab for now),
  PASS. **Step 5:** Commit `feat(mobile): tabs Today, Ask and Profile`.

### Task 7: The Echo device screen

**Files:**
- Rename: `mobile/lib/screens/device_detail_screen.dart` → `echo_device_screen.dart`
  (`EchoDeviceScreen`, title "Echo"), test likewise
- Modify: `mobile/lib/widgets/device_instrument.dart` (`onDetails` optional: no button without it),
  `mobile/lib/main.dart` (pill tap opens it), `mobile/lib/screens/home_screen.dart`
  (firmware tip "Open Echo", `onOpenDevice`)
- Test: `mobile/test/screens/echo_device_screen_test.dart`, `mobile/test/screens/today_screen_test.dart`

- [ ] **Step 1: Failing tests:** the screen shows the instrument (Mute Echo calls `setMuted(true)`),
  the status rows, firmware and "Forget device"; the firmware tip says "Open Echo" and calls
  `onOpenDevice`.
- [ ] **Step 2-4:** FAIL, implement, PASS. **Step 5:** Commit `feat(mobile): the Echo screen`.

### Task 8: Profile

**Files:**
- Create: `mobile/lib/screens/profile_screen.dart` (from `settings_screen.dart`, which is removed)
- Modify: `mobile/lib/services/app/spoken_language.dart` (`AccountInfo.name`, `AccountApi.setName`),
  `mobile/lib/services/api/auth_api.dart`, `mobile/lib/main.dart`
- Test: `mobile/test/screens/profile_screen_test.dart` (from `settings_screen_test.dart`)

**Interfaces:**
- `ProfileScreen({deviceController, appController, sessionController, networkPolicy, preferences,
  onRequireOnboarding, onOpenTranscripts, onOpenDevice, accountApi, ...builders})`.
- Layout: account card (name or "Add your name", email · language), Echo device card (state ·
  battery · firmware, tap → `onOpenDevice`), "ECHO DOES": Apps (connected app names), Notifications,
  Activity, [On this iPhone]; "YOU": Voices, Language, Privacy, Appearance; then "What Echo can do";
  then one row "Devices, server, diagnostics, about" opening a page with those four rows.
- Name dialog prefilled with the account name, else the own voice profile's name.

- [ ] **Step 1: Failing tests:** groups in order; Name saved via `setName`; name prefilled from the
  own voice; the device card opens the device screen; the "more" row lists Devices, Server
  connection, Diagnostics, About; fits 320 wide at 1.3 text scale.
- [ ] **Step 2-4:** FAIL, implement, PASS. **Step 5:** Commit `feat(mobile): Profile, with every setting`.

### Task 9: Ask is one thread

**Files:**
- Modify: `mobile/lib/services/api/chat_api.dart` (`getThread()`), `mobile/lib/models/chat_session.dart`
  (`kind`, message `source`, `when`, `routineId`, `aboutPhotoId`), `mobile/lib/models/chat_message.dart`,
  `mobile/lib/services/chat/chat_controller.dart`, `mobile/lib/screens/chat_screen.dart`,
  `mobile/lib/widgets/message_bubble.dart`, `mobile/lib/services/chat/voice_updates_service.dart`
  (`onNew` callback), `mobile/lib/services/app/app_lifecycle_coordinator.dart`
- Test: `mobile/test/services/chat/chat_controller_test.dart`, `mobile/test/screens/ask_screen_test.dart`

**Interfaces:**
- `ChatController.openThread()`, `ChatState.isThread`, `ChatMessage.byVoice`, `.when`, `.routine`.
- ChatScreen opens the thread on start; `askRequest` sends in the thread; `threadUpdates` reloads it
  when it is shown and idle; user messages by voice show "By voice · HH:MM"; a day label between days;
  a routine answer shows "ROUTINE" in a tinted panel and its instruction is hidden.

- [ ] **Step 1: Failing tests:** controller opens the thread and sends typed questions with its id;
  `newChat` then send uses no session id; an ask request lands in the thread; screen shows
  "By voice · 08:02"; legacy thread message without source shows "By voice"; a routine answer shows
  "Routine"; a thread update reloads.
- [ ] **Step 2-4:** FAIL, implement, PASS. **Step 5:** Commit `feat(mobile): Ask is one thread with Echo`.

### Task 10: Photo answers in Ask

**Files:**
- Modify: `mobile/lib/widgets/message_bubble.dart` (`PhotoAnswer` layout: photo 260 high with
  "Echo's camera · HH:MM", answer, chips), `mobile/lib/services/api/photo_api.dart`
  (`askAboutPhoto(id, question) → PhotoFollowUp`), `mobile/lib/services/chat/chat_controller.dart`
  (`askAboutPhoto`, `photoContext`), `mobile/lib/screens/chat_screen.dart`,
  `mobile/lib/utils/photo_follow_ups.dart`
- Test: `mobile/test/widgets/photo_message_test.dart`, `mobile/test/utils/photo_follow_ups_test.dart`

**Interfaces:**
- `String translateRequest(String language)` ("Traducilo" / "Translate it");
  `String reminderRequest(DateTime when, String language)` ("Ricordamelo giovedì 23 ottobre alle 9:00" /
  "Remind me on Thursday 23 October at 9:00"; midnight → no time);
  `String reminderChipLabel(DateTime when, DateTime now)` ("Remind me at 15:00" today, "Remind me
  tomorrow", weekday within 6 days, else "Remind me 23 Nov").
- "Translate it" → `askAboutPhoto(photoId, translateRequest(lang))`; "Ask more" focuses the composer
  with `photoContext = photoId` (hint "Ask about this photo", a clear chip); "Remind me…" →
  `send(reminderRequest(...))`.

- [ ] **Step 1: Failing tests** for the helpers and: chips under a photo answer, Remind only with
  `when`; Translate calls the API with "Traducilo" for an Italian account and reloads the thread;
  Ask more then send asks about the photo.
- [ ] **Step 2-4:** FAIL, implement, PASS. **Step 5:** Commit `feat(mobile): photo answers large, with quick follow-ups`.

### Task 11: Today's top card and greeting

**Files:**
- Create: `mobile/lib/widgets/today_top_card.dart`
- Modify: `mobile/lib/screens/home_screen.dart`, `mobile/lib/services/api/notifications_api.dart`
  (`comingUp(events) → ComingUp?`), `mobile/lib/models/today_insights.dart`
- Test: `mobile/test/widgets/today_top_card_test.dart`, `mobile/test/screens/today_screen_test.dart`

**Interfaces:**
- `sealed class TodayMoment` with `ConfirmMoment(action, more)`, `ComingUpMoment(ComingUp)`,
  `NowMoment(conversation, lastLine)`, `SoFarMoment(lines, conversations, talked, people)`;
  `TodayMoment? pickMoment({pending, comingUp, open, lastLine, today, now})` in that order;
  pending sorted by `expiresAt`.
- `String greeting(DateTime now, String? name)`: "Good morning" (<12), "Good afternoon" (<18),
  "Good evening"; ", Erik" only with a name.
- `String soFarLine(List<ConversationCard> today)`: the three longest titles in time order, joined.

- [ ] **Step 1: Failing tests** for `pickMoment` order, `greeting`, `soFarLine`, "+2 more" opening the
  full list, header "TUESDAY 21 OCTOBER" and "Good afternoon, Erik".
- [ ] **Step 2-4:** FAIL, implement (NeedsYouSection moves to a pushed screen), PASS.
- [ ] **Step 5:** Commit `feat(mobile): Today's top card changes with the moment`.

### Task 12: Today's lists: search, your day, people, earlier; Memories removed

**Files:**
- Create: `mobile/lib/widgets/memory_search.dart` (search field and results, from Memories),
  `mobile/lib/screens/day_screen.dart` (a day: its digest, then its conversations),
  `mobile/lib/screens/week_screen.dart`
- Modify: `mobile/lib/screens/home_screen.dart`, `mobile/lib/widgets/today_sections.dart`
  (photo rows, `PeopleTodayPanel`, `EarlierPanel`; `ActsInPanel` removed),
  `mobile/lib/services/api/memory_api.dart` (`getDigest(DateTime day)` → null on 404),
  `mobile/lib/models/memory.dart` (`ConversationCard.photoId`), `mobile/lib/main.dart`
- Delete: `mobile/lib/screens/memories_screen.dart`, its test (cases moved to Today's test)
- Test: `mobile/test/screens/today_screen_test.dart`, `mobile/test/screens/day_screen_test.dart`

- [ ] **Step 1: Failing tests:** search on Today shows conversations and mentions; a photo row shows
  its thumbnail and "Photo: <title>"; People today lists who was seen today, All opens everyone;
  Earlier shows "This week" then "Yesterday · 6 conversations · <main topic>", a tap opens the day with
  its digest; empty sections hidden; a full Today fits 320 wide at 1.3.
- [ ] **Step 2-4:** FAIL, implement, PASS. **Step 5:** Commit `feat(mobile): Memories moves into Today`.

### Task 13: Verification

- [ ] Backend suite, ruff, `flutter analyze`, `flutter test`, then `flutter build ios --debug --no-codesign`
  and `flutter build apk --debug`, one at a time through the lock; fix what fails, commit.
