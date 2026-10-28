# Today, your way — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Today shows the user's sections (routines, to do, today's agenda, Your day, people, Saved, where you've been, earlier days) in an order they choose and can hide; search becomes a header icon; "Echo is working on…" moves to Ask.

**Architecture:** A pure `TodayLayout` (order + hidden, JSON in the phone's preferences) decides which sections `HomeScreen` builds and in what order; each section is a widget fed by `HomeScreen`'s existing loaders. New widgets: today's agenda, today's stays, the Edit Today page, a search screen. The top card keeps only actions to confirm; what "Now" showed moves into Your day's live row. Ask polls the same "working" endpoint as Today did.

**Tech Stack:** Flutter (Dart 3), shared_preferences, url_launcher, flutter_test.

**Spec:** `docs/superpowers/specs/2026-10-28-today-your-way-design.md`

## Global Constraints

- Flutter app only (`mobile/`); no server change.
- App strings in English.
- Default order: routines, todo, comingUp, yourDay, people, saved, places, earlier; all visible by default.
- Needs you (actions to confirm), the device warnings, the tips and the plan line are not sections: fixed, not in Edit Today.
- The layout lives on this phone (shared_preferences key `today_layout`), never on the server.
- A hidden section stays hidden across updates; a section new to a saved layout appears visible at its default place.
- A visible section with nothing to show is left out (no empty panels).
- No text cut without a way to read it in full (`ExpandableText` or a page behind it).
- `flutter analyze --no-fatal-infos --no-fatal-warnings` and `flutter test` pass (local: `ft.sh`, Flutter 3.41.6).

## Review Focus

1. **A layout saved by an older version (a section missing, an unknown name, broken JSON)** → defaults fill in; new sections visible at their default place; never a crash. Tests: `missing sections are added at their default place`, `unknown names and broken json fall back` (Task 1).
2. **Every section hidden** → Today still shows Needs you and the Edit Today row, so the user can bring sections back. Test: `with every section hidden Edit Today is still there` (Task 7).
3. **No calendar access, or nothing left today** → no Coming up today panel. Test: `no events, no panel` (Task 3).
4. **Places on but no stays today, or Places off** → no Where you've been panel. Tests: `places off, no panel`, `no stays today, no panel` (Task 7).
5. **A voice request still running when the user opens Ask** → the working bubble shows at once, and goes when the answer arrives. Test: `the working bubble shows and goes when the answer arrives` (Task 8).

---

### Task 1: The layout

**Files:**
- Create: `mobile/lib/models/today_layout.dart`, `mobile/lib/services/app/today_layout_store.dart`
- Test: `mobile/test/models/today_layout_test.dart`

**Interfaces:**
- Produces:
  - `enum TodaySection { routines, todo, comingUp, yourDay, people, saved, places, earlier }` with `String get label` → `'From your routines'`, `'To do today'`, `'Coming up today'`, `'Your day'`, `'People'`, `'Saved'`, `"Where you've been"`, `'Earlier days'`.
  - `@immutable final class TodayLayout { const TodayLayout({required List<TodaySection> order, Set<TodaySection> hidden}); static const TodayLayout defaults; List<TodaySection> get visible; bool isHidden(TodaySection); TodayLayout moved(int from, int to); TodayLayout toggled(TodaySection); String toJson(); static TodayLayout fromJson(String? json); }` — `fromJson`: `{"order": [names], "hidden": [names]}`; unknown names dropped; a default section missing from `order` inserted right after the nearest earlier default section present (or first); null/broken → `defaults`. `moved` follows `ReorderableListView` indices (`to` after removal adjustment: if `to > from` then `to - 1`).
  - `final class TodayLayoutStore { TodayLayoutStore({Future<SharedPreferences> Function()? preferences}); static const key = 'today_layout'; Future<TodayLayout> load(); Future<void> save(TodayLayout layout); }`.

- [ ] **Step 1: Write the failing tests** — `defaults are the user's order, all visible`; `moved and toggled`; `round trip through json`; `missing sections are added at their default place` (saved `[routines, todo, yourDay, people, saved, earlier]` with `hidden: [people]` → `comingUp` after `todo`, `places` after `saved`, `people` still hidden); `unknown names and broken json fall back`; `the store saves and loads` (with `SharedPreferences.setMockInitialValues`).
- [ ] **Step 2: Run** `flutter test test/models/today_layout_test.dart` → FAIL (missing file).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(mobile): Today's layout, its order and hidden sections`

---

### Task 2: Edit Today

**Files:**
- Create: `mobile/lib/screens/edit_today_screen.dart`
- Test: `mobile/test/screens/edit_today_screen_test.dart`

**Interfaces:**
- Consumes: Task 1.
- Produces: `final class EditTodayScreen extends StatefulWidget { const EditTodayScreen({required TodayLayout layout, required ValueChanged<TodayLayout> onChanged}); }` — title **Edit Today**, note **"Drag to reorder. Things to confirm always stay on top."**, a `ReorderableListView` with one row per section (`Key('edit-today-<name>')`, drag handle, the label, a `Switch` `Key('edit-today-switch-<name>')`), a **Reset to default** button (`Key('edit-today-reset')`). Every change calls `onChanged` with the new layout at once.

- [ ] **Step 1: Write the failing tests** — `lists every section with its switch`; `a switch hides a section` (onChanged gets `isHidden(people)`); `dragging reorders` (drag `Key('edit-today-saved')` handle above `routines` → `order.first == saved`); `reset restores the defaults`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `flutter test test/screens/edit_today_screen_test.dart` → PASS.
- [ ] **Step 5: Commit** — `feat(mobile): Edit Today: hide and move sections`

---

### Task 3: Coming up today

**Files:**
- Create: `mobile/lib/widgets/coming_up_today.dart`
- Test: `mobile/test/widgets/coming_up_today_test.dart`

**Interfaces:**
- Produces:
  - `@immutable final class TodayEvent { title, start (local), allDay; static List<TodayEvent> fromPhone(List<Map<String, Object?>> events, DateTime now) }` — keeps events on `now`'s day that are all-day or start at or after `now`; all-day first, then by start.
  - `final class ComingUpTodayPanel extends StatelessWidget { required List<TodayEvent> events; ComingUp? recap; }` — `Key('coming-up-today')`, title **Coming up today**; each event `'HH:MM  title'` (all-day: `'All day  title'`); under the event matching `recap` (same title and start minute) the recap text (no maxLines). `SizedBox.shrink()` without events.

- [ ] **Step 1: Write the failing tests** — `past events are left out, all-day first`; `the recap shows under its event`; `no events, no panel`.
- [ ] **Step 2–4:** FAIL → implement → `flutter test test/widgets/coming_up_today_test.dart` PASS.
- [ ] **Step 5: Commit** — `feat(mobile): Today's agenda, what is still to come`

---

### Task 4: Where you've been

**Files:**
- Modify: `mobile/lib/models/place.dart` (`PlaceVisit.latitude`, `longitude`: `double?`, from the server's `latitude`/`longitude`), `mobile/lib/utils/directions.dart`
- Create: `mobile/lib/widgets/places_today.dart`
- Test: `mobile/test/widgets/places_today_test.dart`, `mobile/test/models/place_test.dart`

**Interfaces:**
- Produces:
  - `Uri visitMapsUri(PlaceVisit visit, {required bool iOS})` — Apple Maps `maps.apple.com/?ll=<lat>,<lng>&q=<label>` on iOS, Google Maps `www.google.com/maps/search/?api=1&query=<lat>,<lng>` otherwise; without coordinates the query is the label/address.
  - `List<PlaceVisit> visitsOn(List<PlaceVisit> visits, DateTime day)` — arrived on that local day, oldest first.
  - `final class PlacesTodayPanel extends StatelessWidget { required List<PlaceVisit> visits; required void Function(PlaceVisit) onOpen; required VoidCallback onSeeAll; }` — `Key('places-today')`, title **Where you've been**, "See all" (`Key('places-see-all')`); one row per stay (`Key('place-<id>')`): `'HH:MM'` (and `'–HH:MM'` when it left) and `visit.label` (full, no maxLines); a tap calls `onOpen`. Nothing without visits.

- [ ] **Step 1: Write the failing tests** — parse `latitude`/`longitude`; `visitMapsUri` on both platforms and without coordinates; `visitsOn` keeps today's only, oldest first; panel rows, tap and See all; `no stays, no panel`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `feat(mobile): today's stays, each one a tap from the map`

---

### Task 5: The top card keeps Needs you; Your day shows the conversation going on

**Files:**
- Modify: `mobile/lib/widgets/today_top_card.dart`, `mobile/lib/widgets/today_sections.dart` (`YourDayPanel`, `_NowRow`)
- Test: `mobile/test/widgets/today_top_card_test.dart`, `mobile/test/screens/today_screen_test.dart`

**Interfaces:**
- Produces:
  - `pickMoment({required List<PendingAction> pending})` → `ConfirmMoment?` only; `ComingUpMoment`, `NowMoment`, `SoFarMoment`, `soFarLine` and their cards removed; `TodayTopCard` drops `onOpenConversation`.
  - `YourDayPanel` gains `String? lastLine` and `DateTime now`; the live row (`Key('day-now')`) shows `'Now · <duration>'`, who (`'with A, B'`), the title, and the last line (`'"…line…"'`, full, no maxLines) when known.

- [ ] **Step 1: Update the tests** — top card: only actions produce a moment; Your day: `the live row says how long, with whom and the last line heard`. Remove the tests of the removed moments.
- [ ] **Step 2–4:** FAIL → implement (HomeScreen passes `_lastLine`, stops loading coming-up for the card) → `flutter test test/widgets/today_top_card_test.dart test/screens/today_screen_test.dart` PASS.
- [ ] **Step 5: Commit** — `feat(mobile): the top card is only for what needs you; Your day shows the conversation going on`

---

### Task 6: Search, from an icon

**Files:**
- Create: `mobile/lib/screens/memory_search_screen.dart`
- Modify: `mobile/lib/screens/home_screen.dart` (header action, field removed)
- Test: `mobile/test/screens/memory_search_screen_test.dart`, `mobile/test/screens/today_screen_test.dart`

**Interfaces:**
- Produces: `final class MemorySearchScreen extends StatefulWidget { required MemoriesController memories; required DateTime Function() clock; required void Function(String id) onOpen; }` — an app bar with `MemorySearchField` (autofocus) and `MemorySearchView` below; leaving clears the query. Today's header gets a `HeaderIconButton` `Key('today-search')` (search icon, tooltip **Search your memory**) opening it.

- [ ] **Step 1: Tests** — `the search icon opens the search`; the existing Today search tests move to the search screen (typing a query shows results, opening one calls `onOpen`).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `feat(mobile): search your memory from an icon on Today`

---

### Task 7: Today in the user's order

**Files:**
- Modify: `mobile/lib/screens/home_screen.dart`, `mobile/lib/main.dart`
- Test: `mobile/test/screens/today_screen_test.dart`

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces: `HomeScreen` gains `TodayLayoutStore? layoutStore` and `ValueListenable<bool>? placesOn` (`AppRuntime.maybeCoordinator?.placesVisited.on` in `main.dart`; places need `api is PlacesApi`). After the fixed blocks (device warnings, tips, Needs you, plan line) the sections follow `layout.visible`, each left out when it has nothing; at the end an **Edit Today** row (`Key('today-edit')`) opening `EditTodayScreen`, which saves through the store and rebuilds. Agenda: `upcomingEvents(within: end of day − now)` → `TodayEvent.fromPhone`, recap from `comingUp(events within the hour)`. Places: `listVisits()` → `visitsOn(today)`, reloaded on refresh; tap → `launchUrl(visitMapsUri(..), externalApplication)`; See all → `PlacesVisitedScreen`. `WorkingSection` no longer on Today.

- [ ] **Step 1: Write the failing tests** — `sections follow the saved order` (saved order with Saved first → Saved above routines); `a hidden section is not shown`; `with every section hidden Edit Today is still there`; `Edit Today saves the new layout`; `places off, no panel`; `no stays today, no panel`; `today's stays are on Today when places are on`; `the agenda lists what is still to come today`; `working requests are not on Today any more`.
- [ ] **Step 2–4:** FAIL → implement → `flutter analyze` and `flutter test` PASS.
- [ ] **Step 5: Commit** — `feat(mobile): Today in your order, with your agenda and where you've been`

---

### Task 8: "Echo is working on…" in Ask; docs

**Files:**
- Modify: `mobile/lib/screens/chat_screen.dart`, `mobile/lib/main.dart`, `README.md`, `docs/PROJECT-STATUS.md`, `docs/ROADMAP.md`
- Test: `mobile/test/screens/chat_screen_test.dart`

**Interfaces:**
- Consumes: `VoiceWorkingApi.getVoiceWorking()`, `workingLabel(WorkingItem)` (`widgets/today_sections.dart`).
- Produces: `ChatScreen` gains `Stream<Object?>? segmentUploadedStream` and `Duration workingPollInterval` (default 5 s). While the thread with Echo is shown it loads the working items on start, on each upload, on each thread update, and again every `workingPollInterval` while any are left; each shows as an Echo bubble at the bottom of the thread (`Key('chat-working-<key>')`, `workingLabel(item)` with a `TypingIndicator`).

- [ ] **Step 1: Write the failing tests** — `the working bubble shows and goes when the answer arrives`; `no working bubble in another chat`.
- [ ] **Step 2–4:** FAIL → implement → `flutter analyze` and `flutter test` PASS.
- [ ] **Step 5: Docs** — README (Today and Ask paragraphs), PROJECT-STATUS (28/10: Today your way), ROADMAP (point 15 done; next: spoken answers).
- [ ] **Step 6: Commit** — `feat(mobile): Ask shows what Echo is working on; docs`
