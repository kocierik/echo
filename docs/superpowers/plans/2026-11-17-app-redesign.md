# The App Redesigned Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Echo's Flutter app restyled Apple premium (Midnight dark, Graphite light, one azure accent, system font, iOS pieces where they show) and reorganised into Today, Ask and Library, with the pendant and settings behind the user's circle.

**Architecture:** The app stays a `MaterialApp` (hybrid approach). Phase 1 changes theme tokens only. Phase 2 gives each tab its own `Navigator`, replaces the Profile tab with Library, and moves Profile's rows into an account sheet. Phase 3 builds the Library screen. Phase 4 converts screens to large titles and inset grouped lists, settings first through their shared components.

**Tech Stack:** Flutter (stable, in Docker), `package:flutter/cupertino.dart`, `flutter_test`. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-17-app-redesign-design.md` (read it first: colour table, structure, where every feature goes).

## Global Constraints

- Every colour comes from an `EchoPalette` token defined in both themes; no literal colours in widgets.
- Colour values exactly as the spec's table; light accent `#0A6FD6`, dark accent `#64D2FF`; no orange anywhere.
- The system font: no `fontFamily` in the theme (Flutter's platform typography gives San Francisco on iOS). Archivo stays bundled only for the licence entry in `lib/main.dart:42-45` and an optional wordmark.
- Text contrast ≥ 4.5:1 for normal text in both themes.
- Touch targets ≥ 44×44; VoiceOver labels on every control; text scales (Dynamic Type) without overflow; no animation when `MediaQuery.disableAnimations` is true.
- No new package; Cupertino widgets come from Flutter's `cupertino` library.
- The web build (`mobile/web`, served at `/app`) keeps working.
- `flutter analyze`: the 2 existing infos, no new ones. All tests green at the end of every task.
- Never trigger `.github/workflows/ios-unsigned.yml`; the user starts iOS builds.
- App checks, from `/home/erik/echo/mobile`:
  ```bash
  docker run --rm -v "$PWD":/app -w /app -v echo-pub-cache:/root/.pub-cache ghcr.io/cirruslabs/flutter:stable sh -c "flutter analyze; flutter test; chown -R $(id -u):$(id -g) /app"
  ```
  A single file: replace `flutter test` with `flutter test test/path_test.dart`.
- Commits: one per task, message written to a file and committed with `git commit -F <file>`, subject describing behaviour (`feat(app): …`), ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Push at the end of each phase.
- Tests that assert old colours, labels or layout are updated to the new design, never deleted to make a task pass.

## Review Focus

1. **Text at the largest Dynamic Type size**: tab bar labels, Library tiles and the account sheet's pendant card wrap or grow instead of overflowing. Pinned in Task 3 and Task 7 (`textScaler: TextScaler.linear(2.0)`, no overflow exceptions).
2. **An app updated from the previous version**: a stored tab index 2 (was Profile) opens Library; a stored Today layout naming `people`, `saved`, `places` or `earlier` loads without them. Pinned in Task 2 and Task 6.
3. **Back on Android and the web**: the system back gesture pops the current tab's stack before leaving the app. Pinned in Task 4.
4. **A notification or request arriving while the user is deep in another tab**: it opens in the right tab, with the tab bar still visible. Pinned in Task 6.
5. **One Library source failing** (offline, a 500): its tile shows "—" and the others still show their counts. Pinned in Task 7.

---

## Phase 1: Theme

### Task 1: Midnight and Graphite, the system font, iOS transitions

**Files:**
- Modify: `mobile/lib/theme/app_theme.dart` (palette values, a new `onAccent` role, `_textTheme`, `pageTransitionsTheme`, filled buttons)
- Modify: `mobile/test/theme/app_theme_test.dart`

**Interfaces:**
- Produces: `EchoPalette.onAccent` (text and icons on an accent fill), in the constructor, `copyWith` and `lerp`. Values: dark `#00141C`, light `#FFFFFF`.
- Produces: the spec's colour table in `EchoPalette.dark` (Midnight) and `EchoPalette.light` (Graphite).

Legacy roles keep their names in this task and take new values, so no widget changes: `live` and `liveText` = accent; `liveGlow` = accent soft; `attention` = `surface`; `onAttention` = `text`; `onAttention2` = `text2`; `chrome` = the translucent bar colour (dark `0xEB121214`, light `0xEBF5F5F2`); `chromeRaised` = `surface2`; `chromeLine` = `border`; `onChrome` = `text`; `onChromeMuted` = `text2`; `tint` = accent soft.

- [ ] **Step 1: Write the failing tests** in `app_theme_test.dart`, replacing the first three tests:

```dart
test('Graphite: warm white ground, white panels, the darker azure', () {
  final palette = AppTheme.light.extension<EchoPalette>()!;
  expect(palette.background, const Color(0xFFF5F5F2));
  expect(palette.surface, const Color(0xFFFFFFFF));
  expect(palette.text, const Color(0xFF1D1D1F));
  expect(palette.text2, const Color(0xFF6E6E73));
  expect(palette.accent, const Color(0xFF0A6FD6));
  expect(palette.onAccent, const Color(0xFFFFFFFF));
  expect(palette.live, palette.accent);
});

test('Midnight: black ground, graphite panels, the pendant azure', () {
  final palette = AppTheme.dark.extension<EchoPalette>()!;
  expect(palette.background, const Color(0xFF000000));
  expect(palette.surface, const Color(0xFF1C1C1E));
  expect(palette.text, const Color(0xFFE8E8ED));
  expect(palette.accent, const Color(0xFF64D2FF));
  expect(palette.onAccent, const Color(0xFF00141C));
  expect(palette.red, const Color(0xFFFF453A));
});

test('the primary button is the accent, links are the accent', () {
  for (final theme in [AppTheme.dark, AppTheme.light]) {
    final palette = theme.extension<EchoPalette>()!;
    final filled = theme.filledButtonTheme.style!;
    expect(filled.backgroundColor!.resolve({}), palette.accent);
    expect(filled.foregroundColor!.resolve({}), palette.onAccent);
    expect(theme.textButtonTheme.style!.foregroundColor!.resolve({}), palette.accent);
  }
});

test('no Archivo: the platform font (San Francisco on iOS)', () {
  for (final theme in [AppTheme.dark, AppTheme.light]) {
    expect(theme.textTheme.bodyMedium!.fontFamily, isNot('Archivo'));
    expect(theme.textTheme.displayLarge!.fontFamily, isNot('Archivo Expanded'));
  }
});

test('pages slide in from the side and swipe back, on every platform', () {
  for (final theme in [AppTheme.dark, AppTheme.light]) {
    for (final platform in TargetPlatform.values) {
      expect(theme.pageTransitionsTheme.builders[platform], isA<CupertinoPageTransitionsBuilder>());
    }
  }
});
```

Keep the existing contrast and 44 pt tests; they must pass with the new values (accent on ground in Graphite is 4.52:1).

- [ ] **Step 2: Run it, expect FAIL** (`flutter test test/theme/app_theme_test.dart`: colours differ, `onAccent` undefined).
- [ ] **Step 3: Implement.** Palette values from the spec; `onAccent`; `_textTheme` without `family` (sizes and weights unchanged, `letterSpacing` left to the platform); `ThemeData(fontFamily: null, pageTransitionsTheme: PageTransitionsTheme(builders: {for (final p in TargetPlatform.values) p: const CupertinoPageTransitionsBuilder()}))`; filled buttons accent on `onAccent`. Remove `AppTheme.fontFamily` and `titleFamily` and their uses.
- [ ] **Step 4: Run the whole app check.** Expected: analyze unchanged, every test passes. A widget test failing on an old colour or the old font is updated to the new token, not deleted.
- [ ] **Step 5: Commit** — `feat(app): Midnight and Graphite, one azure accent, the system font`. Push (end of phase 1).

---

## Phase 2: Navigation

### Task 2: The third tab is Library

**Files:**
- Modify: `mobile/lib/services/app/app_controller.dart` (`profileTab` → `libraryTab`, same index 2)
- Modify: every use of `AppController.profileTab` (`lib/main.dart`, tests)
- Test: `mobile/test/services/app/app_controller_test.dart`

**Interfaces:**
- Produces: `static const libraryTab = 2;` (`todayTab = 0`, `askTab = 1` unchanged). `AppViewState.tabCount` stays 3.

- [ ] **Step 1: Write the failing test**

```dart
test('a stored third tab (Profile before) opens Library', () async {
  preferences.values[AppController.selectedTabKey] = 2;
  final controller = await build();
  expect(controller.value.selectedTab, AppController.libraryTab);
});
```
(Use the file's existing setup helper in place of `build()`.)

- [ ] **Step 2: Run it, expect FAIL** (`libraryTab` undefined).
- [ ] **Step 3: Rename the constant**; the stored key and value are unchanged.
- [ ] **Step 4: Run the whole app check**, expect PASS.
- [ ] **Step 5: Commit** — `feat(app): the third tab is Library`.

### Task 3: The tab bar says Today, Ask, Library

**Files:**
- Modify: `mobile/lib/widgets/echo_nav_bar.dart` (the two side destinations; translucent bar)
- Test: `mobile/test/widgets/app_shell_test.dart`

**Interfaces:**
- Consumes: `AppController.libraryTab`.
- Produces: destinations keyed `echo-nav-0` (Today, `CupertinoIcons.clock`) and `echo-nav-2` (Library, `CupertinoIcons.square_stack_3d_up`); the Ask button keeps its key and behaviour. The bar uses `palette.chrome` with a `BackdropFilter` blur (sigma 20), and a hairline `palette.chromeLine` on top.

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('the bar offers Today, Ask and Library', (tester) async {
  await pumpShell(tester);
  expect(find.bySemanticsLabel('Today'), findsOneWidget);
  expect(find.bySemanticsLabel('Library'), findsOneWidget);
  expect(find.bySemanticsLabel('Profile'), findsNothing);
});

testWidgets('at the largest text size the bar does not overflow', (tester) async {
  await pumpShell(tester, textScaler: const TextScaler.linear(2.0));
  expect(tester.takeException(), isNull);
});
```
(Use the file's existing pump helper; add a `textScaler` parameter wrapping in `MediaQuery`.)

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the labels, icons and translucent bar.
- [ ] **Step 4: Run the whole app check**, expect PASS.
- [ ] **Step 5: Commit** — `feat(app): the tab bar says Today, Ask and Library`.

### Task 4: Each tab keeps its own stack

**Files:**
- Modify: `mobile/lib/widgets/echo_app_shell.dart`
- Modify: `mobile/lib/main.dart` (`MainShell` owns the keys)
- Test: `mobile/test/widgets/app_shell_test.dart`

**Interfaces:**
- Produces: `EchoAppShell({…, required List<GlobalKey<NavigatorState>> navigatorKeys})`, one key per tab. Each child is wrapped in `Navigator(key: navigatorKeys[i], onGenerateRoute: (_) => CupertinoPageRoute(builder: (_) => child))` inside the existing `IndexedStack`. Selecting the already selected tab pops its navigator to the first route. The whole stack is wrapped in `NavigatorPopHandler` so the system back pops the current tab's navigator first.
- Produces: `MainShell` holds `final tabNavigators = List.generate(3, (_) => GlobalKey<NavigatorState>())` (state; `MainShell` becomes a `StatefulWidget`), passed to the shell and used by Task 6.

Screens pushed with `Navigator.of(context)` from inside a tab now land on that tab's navigator, above which the tab bar stays visible. Sheets and dialogs that must cover the bar use `useRootNavigator: true`.

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('a page opened in Today is still there after visiting Library', (tester) async {
  await pumpShell(tester);
  await openTestPageInToday(tester);          // pushes a page titled 'Inner'
  await tester.tap(find.byKey(const Key('echo-nav-2')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('echo-nav-0')));
  await tester.pumpAndSettle();
  expect(find.text('Inner'), findsOneWidget);
  expect(find.byKey(const Key('echo-nav-0')), findsOneWidget); // the bar is still there
});

testWidgets('tapping the active tab again goes back to its top', (tester) async {
  await pumpShell(tester);
  await openTestPageInToday(tester);
  await tester.tap(find.byKey(const Key('echo-nav-0')));
  await tester.pumpAndSettle();
  expect(find.text('Inner'), findsNothing);
});

testWidgets('system back closes the tab page before leaving the app', (tester) async {
  await pumpShell(tester);
  await openTestPageInToday(tester);
  final handled = await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(handled, isTrue);
  expect(find.text('Inner'), findsNothing);
});
```
`openTestPageInToday`: a test helper that pumps the shell with a Today child holding a button which pushes a `CupertinoPageRoute` showing `Text('Inner')`.

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** in `EchoAppShell` and `MainShell`.
- [ ] **Step 4: Run the whole app check.** Expected PASS. A test that relied on a pushed page covering the bar is updated to the new behaviour.
- [ ] **Step 5: Commit** — `feat(app): each tab keeps its own pages`.

### Task 5: The account sheet and the user's circle

**Files:**
- Create: `mobile/lib/widgets/account_button.dart`
- Create: `mobile/lib/screens/account_sheet.dart` (takes over `ProfileScreen`'s rows and its `_MoreScreen`)
- Delete: `mobile/lib/screens/profile_screen.dart` once nothing uses it
- Modify: `mobile/lib/screens/settings/memory_screen.dart` (an "Instructions" row at the top, opening today's instructions editor)
- Test: `mobile/test/screens/account_sheet_test.dart` (moved and adapted from `profile_screen_test.dart`)

**Interfaces:**
- Produces: `AccountButton({required VoidCallback onTap, String? initial})`: a 32 pt circle with the user's initial (from `AccountInfo.name`, else the email's first letter, else none), semantics label "Account", 44 pt hit area.
- Produces: `Future<void> showAccountSheet(BuildContext context, {required AppController appController, DeviceController? deviceController, SessionController? sessionController, NetworkPolicy? networkPolicy, SharedPreferences? preferences, VoidCallback? onRequireOnboarding})`: `showModalBottomSheet(useRootNavigator: true, isScrollControlled: true, showDragHandle: true)` around `AccountSheet` with the same parameters.
- `AccountSheet` content, in this order (spec, "The account sheet"):
  1. The pendant card: connection and listening state in words, battery, segments waiting, firmware version, a Mute switch; a tap opens `openEchoDevice` (as today's pill does).
  2. Section "ECHO DOES": Routines, Apps, WhatsApp, Notifications, Spoken answers, Activity.
  3. Section "YOU": About you (opens `MemoryScreen`), Voices, Assistants, Language.
  4. Section "SETTINGS": Appearance, Privacy, Places visited, Health, Plan, Devices, Server connection, Diagnostics, What Echo can do, Example data, About.
  Each row opens the same screen it opens today (reuse `ProfileScreen`'s navigation code; do not rewrite the destination screens).

- [ ] **Step 1: Write the failing tests** (move `profile_screen_test.dart` to `account_sheet_test.dart`, keep its fakes):

```dart
testWidgets('the sheet lists the pendant, then Echo does, You and Settings', (tester) async {
  tester.view.physicalSize = const Size(1200, 8000); // every row built at once
  addTearDown(tester.view.reset);
  await pumpAccountSheet(tester);
  const order = ['ECHO DOES', 'Routines', 'Apps', 'WhatsApp', 'Notifications', 'Spoken answers',
      'Activity', 'YOU', 'About you', 'Voices', 'Assistants', 'Language', 'SETTINGS',
      'Appearance', 'Privacy', 'Places visited', 'Health', 'Plan', 'Devices',
      'Server connection', 'Diagnostics', 'What Echo can do', 'Example data', 'About'];
  final shown = tester
      .widgetList<Text>(find.descendant(of: find.byType(AccountSheet), matching: find.byType(Text)))
      .map((t) => t.data)
      .where(order.contains)
      .toList();
  expect(shown, order);
  expect(find.byKey(const Key('account-pendant')), findsOneWidget); // the pendant card, first
});

testWidgets('About you opens the memory page, which offers Instructions', (tester) async {
  await pumpAccountSheet(tester);
  await tester.tap(find.text('About you'));
  await tester.pumpAndSettle();
  expect(find.text('Instructions'), findsOneWidget);
});

testWidgets('the circle shows the initial and opens the sheet', (tester) async {
  await pumpWithAccountButton(tester, name: 'Erik');
  expect(find.text('E'), findsOneWidget);
  await tester.tap(find.bySemanticsLabel('Account'));
  await tester.pumpAndSettle();
  expect(find.text('ECHO DOES'), findsOneWidget);
});
```
Keep, adapted to the sheet, every test of `profile_screen_test.dart` that checks what a row opens or does (log out, delete account, theme choice, places switch).

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `AccountButton`, `AccountSheet`, `showAccountSheet`, the Instructions row; delete `ProfileScreen` and `_MoreScreen` when nothing references them.
- [ ] **Step 4: Run the whole app check**, expect PASS.
- [ ] **Step 5: Commit** — `feat(app): the pendant and the settings behind the account circle`.

### Task 6: Today keeps the day; requests land in their tab

**Files:**
- Modify: `mobile/lib/models/today_layout.dart` (remove `people`, `saved`, `places`, `earlier`)
- Modify: `mobile/lib/screens/home_screen.dart` (drop those sections and their loaders; the `AccountButton` beside the title)
- Modify: `mobile/lib/screens/chat_screen.dart` (the `AccountButton` in Ask's header)
- Modify: `mobile/lib/main.dart` (`MainShell`: Library as the third child, a placeholder `LibraryScreen` until Task 7; person and tasks requests push on Library's navigator)
- Test: `mobile/test/models/today_layout_test.dart`, `mobile/test/widget_test.dart` or the shell test that drives `MainShell`

**Interfaces:**
- Consumes: `AppController.libraryTab`, `MainShell.tabNavigators` (Task 4), `AccountButton`, `showAccountSheet` (Task 5).
- Produces: `TodaySection` = `routines, todo, comingUp, yourDay` (Needs you, Now and the pendant pill stay fixed, as today).
- Produces: in `MainShell`, `PersonRequestListener` and `TasksRequestListener` select `libraryTab`, then push `PersonScreen` / `TasksPage` on `tabNavigators[AppController.libraryTab].currentState`.

- [ ] **Step 1: Write the failing tests**

```dart
test('a layout saved before the Library keeps the sections Today still has', () {
  final layout = TodayLayout.fromJson(
      '{"order":["people","todo","saved","yourDay","earlier","places"],"hidden":["people"]}');
  // The saved order of what remains is kept; the sections it lacked are added back
  expect(layout.order.indexOf(TodaySection.todo), lessThan(layout.order.indexOf(TodaySection.yourDay)));
  expect(layout.order.toSet(), TodaySection.values.toSet());
  expect(layout.hidden, isEmpty);
});

testWidgets('a person request opens the person in Library, with the bar', (tester) async {
  await pumpMainShell(tester);                 // the app's existing shell harness
  appController.pendingPersonId.value = 'person-1';  // what a person notification sets
  await tester.pumpAndSettle();
  expect(appController.value.selectedTab, AppController.libraryTab);
  expect(find.byType(PersonScreen), findsOneWidget);
  expect(find.byKey(const Key('echo-nav-2')), findsOneWidget);
});
```
(Use the existing names for the request API and harness; the assertions are the point.)

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Edit Today lists only the four sections.
- [ ] **Step 4: Run the whole app check**, expect PASS.
- [ ] **Step 5: Commit** — `feat(app): Today keeps the day; people and tasks open in Library`. Push (end of phase 2).

---

## Phase 3: Library

### Task 7: The Library screen

**Files:**
- Create: `mobile/lib/services/library_counts.dart`
- Create: `mobile/lib/screens/library_screen.dart`
- Modify: `mobile/lib/main.dart` (the real `LibraryScreen` in place of the placeholder)
- Test: `mobile/test/services/library_counts_test.dart`, `mobile/test/screens/library_screen_test.dart`

**Interfaces:**
- Produces, in `library_counts.dart`:
  ```dart
  final class LibraryCounts {
    final int? people; final List<String> faces; // up to 3 initials
    final int? saved; final int? openTasks; final int? visitsThisWeek; final int? documents;
  }
  Future<LibraryCounts> loadLibraryCounts({required MemoryApi memory, required SavedApi saved,
      required DocumentsApi documents, required PlacesApi places, required bool placesOn, DateTime? now});
  final class LibraryDay { final DateTime day; final int conversations; final List<String> people; }
  List<LibraryDay> thisWeek(List<ConversationCard> cards, DateTime now); // last 7 local days, newest first, days with none left out
  ```
  Each count comes from its own call (`listPeople`, `getSaved`, `listTasks(done: false)`, `listVisits` for the last 7 days, `listDocuments`); a call that throws leaves its field `null` and never fails the others. `visitsThisWeek` is `null` without a call when `placesOn` is false.
- Produces: `LibraryScreen({required Future<LibraryCounts> Function() loadCounts, required MemoriesController memories, …openers})`. Layout per spec: `CupertinoSliverNavigationBar(largeTitle: Text('Library'), trailing: AccountButton(...))`; a `CupertinoSearchTextField` ("Search what you heard") that opens `MemorySearchScreen`; "THIS WEEK" rows from `thisWeek(memories.state.conversations, now)` opening `DayScreen`, and an "Earlier" row; a two-column grid of tiles with copy exactly:

  | Tile | Subtitle | Opens |
  |---|---|---|
  | People | `{n} saved` + up to 3 faces | `PeopleScreen` |
  | Saved | `{n} items` | `SavedScreen` |
  | To do | `{n} open` | `TasksPage` |
  | Places | `{n} this week`, or `Off` when places are off | `PlacesVisitedScreen` |
  | Map | `People and topics` | `MemoryGraphScreen` |
  | Documents | `{n}` | `DocumentsScreen` |

  A `null` count shows `—`. Counts reload when the tab is shown and on pull to refresh.

- [ ] **Step 1: Write the failing tests**

```dart
test('one failing source does not hide the others', () async {
  final counts = await loadLibraryCounts(memory: FakeMemory(people: 14, openTasks: 3),
      saved: ThrowingSaved(), documents: FakeDocs(3), places: FakePlaces(8), placesOn: true);
  expect(counts.people, 14);
  expect(counts.saved, isNull);
  expect(counts.openTasks, 3);
  expect(counts.visitsThisWeek, 8);
  expect(counts.documents, 3);
});

test('places off: no call, no count', () async {
  final places = FakePlaces(8);
  final counts = await loadLibraryCounts(memory: FakeMemory(), saved: FakeSaved(0),
      documents: FakeDocs(0), places: places, placesOn: false);
  expect(counts.visitsThisWeek, isNull);
  expect(places.calls, 0);
});

test('this week: one row per day with conversations, newest first', () {
  final now = DateTime(2026, 11, 17, 18);
  final days = thisWeek([card(DateTime(2026, 11, 17, 9), ['Marco']), card(DateTime(2026, 11, 17, 12), ['Giulia']),
      card(DateTime(2026, 11, 16, 13), ['Marco']), card(DateTime(2026, 11, 9, 10), [])], now);
  expect(days.map((d) => d.day), [DateTime(2026, 11, 17), DateTime(2026, 11, 16)]);
  expect(days.first.conversations, 2);
  expect(days.first.people, ['Marco', 'Giulia']);
});

testWidgets('the tiles show their counts, and a dash for an unknown one', (tester) async {
  await pumpLibrary(tester, counts: LibraryCounts(people: 14, faces: ['M', 'G'], saved: null,
      openTasks: 3, visitsThisWeek: 8, documents: 3));
  expect(find.text('14 saved'), findsOneWidget);
  expect(find.text('—'), findsOneWidget);
  expect(find.text('3 open'), findsOneWidget);
  expect(find.text('8 this week'), findsOneWidget);
});

testWidgets('People opens the people page, inside Library', (tester) async {
  await pumpLibrary(tester, counts: const LibraryCounts(people: 1, faces: ['M']));
  await tester.tap(find.text('People'));
  await tester.pumpAndSettle();
  expect(find.byType(PeopleScreen), findsOneWidget);
});

testWidgets('at the largest text size the Library does not overflow', (tester) async {
  await pumpLibrary(tester, counts: const LibraryCounts(people: 14), textScaler: const TextScaler.linear(2.0));
  expect(tester.takeException(), isNull);
});
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `library_counts.dart` and `LibraryScreen`; `MainShell` passes `() => loadLibraryCounts(...)` built from its `ApiService` and the same `MemoriesController` Today uses (lift it into `MainShell` if `HomeScreen` creates its own).
- [ ] **Step 4: Run the whole app check**, expect PASS.
- [ ] **Step 5: Commit** — `feat(app): the Library, everything Echo keeps in one place`. Push (end of phase 3).

---

## Phase 4: Screens

### Task 8: Settings pages on iOS lists, through their shared components

**Files:**
- Modify: `mobile/lib/screens/settings/settings_components.dart` (`SettingsPageScaffold`, `SettingsSection`, `SettingsRow`, `SettingsMessage`)
- Test: `mobile/test/screens/settings/settings_components_test.dart` (create)

**Interfaces:**
- Produces: `SettingsPageScaffold` renders a `CupertinoSliverNavigationBar` large title and its sections as `CupertinoListSection.insetGrouped` (backgrounds `palette.surface` on `palette.background`, separators `palette.border`); `SettingsRow` becomes a `CupertinoListTile` with the same parameters (`icon`, `title`, `subtitle`, `value`, `onTap`, `trailing`, `destructive`, `leading`), a chevron when `onTap` is set, `palette.red` text when `destructive`. Public constructors unchanged, so every settings page changes without edits.

- [ ] **Step 1: Write the failing tests**: a page built with `SettingsPageScaffold(title: 'Privacy', children: [SettingsSection('KEPT'), SettingsRow(icon: CupertinoIcons.lock, title: 'Audio', onTap: () {})])` shows `find.byType(CupertinoSliverNavigationBar)`, `find.byType(CupertinoListSection)`, `find.byType(CupertinoListTile)` and a chevron; a destructive row's title colour is `palette.red`; the row's tap target is ≥ 44 high.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the whole app check.** Settings page tests that find widgets by Material type are updated to the Cupertino ones.
- [ ] **Step 5: Commit** — `feat(app): settings pages as iOS lists`.

### Task 9: Shared blocks for the main screens

**Files:**
- Create: `mobile/lib/widgets/echo_large_title.dart`, `mobile/lib/widgets/echo_grouped.dart`
- Test: `mobile/test/widgets/echo_large_title_test.dart`

**Interfaces:**
- Produces: `EchoLargeTitlePage({required String title, Widget? trailing, required List<Widget> slivers, Future<void> Function()? onRefresh})`: a `CustomScrollView` with `CupertinoSliverNavigationBar` (translucent `palette.chrome`), optional `CupertinoSliverRefreshControl`, then `slivers`.
- Produces: `EchoGroup({String? header, required List<Widget> children})`: a rounded `palette.surface` group (radius 14) with `palette.border` hairlines between children, the header in the spec's caption style.

- [ ] **Steps 1-5**: tests that the title collapses when scrolled (the large title's opacity goes to 0 after a 200 px drag), that `onRefresh` runs on pull, and that `EchoGroup` draws n−1 separators for n children; implement; run; commit `feat(app): the large title and grouped blocks`.

### Task 10: Today, Ask and the Library pages on the new blocks

One commit per screen, each with its existing tests updated and the whole app check green:

- [ ] **Today** (`home_screen.dart`): `EchoLargeTitlePage(title: 'Today', trailing: AccountButton)`, the pendant pill under the title, each section an `EchoGroup` in the order of Task 6; "Needs you" items with an accent `Done` chip and a light haptic (`HapticFeedback.lightImpact`) on Done. Commit `feat(app): Today as an iOS page`.
- [ ] **Ask** (`chat_screen.dart`, `message_bubble.dart`): bubbles on `surface` (Echo) and `surface2` (you), the input bar fixed at the bottom on `surface` with the microphone in the accent; the assistant switcher in the header. Commit `feat(app): Ask restyled`.
- [ ] **People and person** (`people_screen.dart`, `person_screen.dart`). Commit `feat(app): People as iOS pages`.
- [ ] **Saved, To do, Places** (`saved_screen.dart`, `saved_item_screen.dart`, `tasks_screen.dart`, `places_visited_screen.dart`). Commit `feat(app): Saved, To do and Places as iOS pages`.
- [ ] **Days and conversations** (`day_screen.dart`, the week screen, `conversation_detail_screen.dart`, `transcript_detail_screen.dart`). Commit `feat(app): days and conversations as iOS pages`.
- [ ] **Map** (`memory_graph_screen.dart`): node colours from the accent and `text2`, the canvas on `background`. Commit `feat(app): the map in the new colours`.

For each: large title where the page is a destination, `EchoGroup` for lists of rows, `CupertinoIcons` for icons it shows, no literal colours, and `MediaQuery.disableAnimations` respected. Push at the end of the phase.

### Task 11: Final check

- [ ] **Step 1:** `rtk grep -rnE "Color\(0x" mobile/lib --include='*.dart' | grep -v lib/theme/` returns nothing (no literal colours outside the theme).
- [ ] **Step 2:** `rtk grep -rnE "live|attention|chrome(Raised|Line)?\b|onChrome" mobile/lib` shows no uses outside `app_theme.dart`; then remove those legacy roles from `EchoPalette` (constructor, fields, `copyWith`, `lerp`) and run the whole app check.
- [ ] **Step 3:** `flutter build web` in the same container succeeds.
- [ ] **Step 4: Commit** — `refactor(app): the palette keeps only the roles the design uses`. Push.
- [ ] **Step 5: USER:** an iOS build, then a look on the phone in both themes and with the largest text size.
