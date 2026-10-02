# Core Beta Mobile Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved Echo iOS-first experience in Flutter: adaptive light/dark styling, truthful global device status, Today privacy control, searchable transcript memory, complete Ask history, hierarchical Settings, onboarding, and device detail.

**Architecture:** A root `AppController` combines existing API session state with the `DeviceController` delivered by the reliability plan. Screens consume immutable view states through `ValueListenableBuilder`; services remain UI-independent. Reusable primitives implement the mockup tokens once. The approved 375×812 HTML mockup is the visual source of truth.

**Tech Stack:** Flutter/Dart, Material 3 primitives, bundled DM Sans font, existing services/controllers, flutter_test golden and semantics tests.

## Visual Source of Truth

- `docs/mockups/echo-mobile/index.html`
- `docs/mockups/echo-mobile/styles.css`
- `docs/mockups/echo-mobile/app.js`
- `docs/superpowers/specs/2026-10-01-core-beta-design.md`

## Global Constraints

- Execute after device reliability and memory controls pass their gates.
- Preserve the approved information architecture: Today, Transcripts, Ask; Settings opens outside the three-tab bar.
- Device state is global and derived from `DeviceController`; screens never infer it from stale booleans.
- Today has four explicit states: listening, muted, connecting, offline.
- Light/dark follows system by default and can be overridden in Settings.
- Use DM Sans from checked-in font assets under its open-font license; no runtime font download.
- Use Material/Lucide-equivalent familiar icons, icon buttons with tooltips, 44×44 minimum targets, cards at 8px radius or less, no nested cards, no negative letter spacing.
- Support 320–430 logical-pixel phones, text scale 1.0–1.3, safe areas, and keyboard insets without horizontal overflow or overlap.
- No waveform decoration, marketing landing screen, device battery percentage until real firmware support exists, or unimplemented controls.
- Do not add a new state-management package.

---

### Task 1: Theme Tokens, Font, and App View State

**Files:**
- Add: `mobile/assets/fonts/DMSans-Regular.ttf`
- Add: `mobile/assets/fonts/DMSans-Medium.ttf`
- Add: `mobile/assets/fonts/DMSans-SemiBold.ttf`
- Add: `mobile/assets/fonts/OFL.txt`
- Modify: `mobile/pubspec.yaml`
- Replace: `mobile/lib/theme/app_theme.dart`
- Create: `mobile/lib/models/app_view_state.dart`
- Create: `mobile/lib/services/app_controller.dart`
- Modify: `mobile/lib/main.dart`
- Test: `mobile/test/theme/app_theme_test.dart`
- Test: `mobile/test/services/app_controller_test.dart`

**Interfaces:**
- `ThemePreference.system|light|dark` persisted in SharedPreferences.
- `AppViewState(session, device, themePreference, selectedTab)` is immutable.
- `AppController extends ValueNotifier<AppViewState>` subscribes once to device/session streams and disposes every subscription.

- [ ] **Step 1: Add licensed font assets**

Download static DM Sans Regular/Medium/SemiBold from the official Google Fonts repository, include its OFL, verify SHA-256 in the task report, and register:

```yaml
flutter:
  fonts:
    - family: DM Sans
      fonts:
        - asset: assets/fonts/DMSans-Regular.ttf
          weight: 400
        - asset: assets/fonts/DMSans-Medium.ttf
          weight: 500
        - asset: assets/fonts/DMSans-SemiBold.ttf
          weight: 600
```

- [ ] **Step 2: Write failing theme tests**

Assert light/dark brightness, DM Sans, semantic success/warning/error colors, 8px maximum card radius, 44px minimum interactive dimensions, and zero letter spacing for display/title styles.

- [ ] **Step 3: Implement exact design tokens**

Dark palette follows mock variables: background `#080A0D`, surface `#111419`, surface2 `#171B21`, text `#F4F6F8`, secondary `#9CA3AE`, blue `#4385FF`, green `#46D69A`, amber `#FFBD59`, red `#FF6B74`. Implement light semantic counterparts from the approved light mock, not generated tints.

- [ ] **Step 4: Write and implement controller tests**

Cover initial restored theme/tab, device stream update, session logout, tab change, theme override, duplicate subscriptions, and disposal. Initialize controller dependencies before `runApp`; no service construction inside screen `build` methods.

- [ ] **Step 5: Verify and commit**

```bash
cd mobile
flutter test test/theme test/services/app_controller_test.dart
flutter analyze
git add mobile/assets mobile/pubspec.yaml mobile/lib/theme mobile/lib/models/app_view_state.dart mobile/lib/services/app_controller.dart mobile/lib/main.dart mobile/test
git commit -m "feat: establish adaptive Echo app foundation"
```

### Task 2: App Shell, Global Status, and Navigation

**Files:**
- Create: `mobile/lib/widgets/echo_app_shell.dart`
- Create: `mobile/lib/widgets/device_status_strip.dart`
- Create: `mobile/lib/widgets/echo_bottom_navigation.dart`
- Modify: `mobile/lib/main.dart`
- Test: `mobile/test/widgets/app_shell_test.dart`

**Interfaces:**
- Shell preserves tab subtree state with `IndexedStack`.
- Status strip maps every `DeviceConnectionState` to approved copy/color/action.
- Settings icon opens a pushed Settings route; it is not a fourth tab.

- [ ] **Step 1: Write failing navigation/status widget tests**

Assert three destinations and semantics labels, selected tab restoration, scroll state retention, 44px targets, safe-area padding, Settings push/pop, and all device status mappings. Verify `listening` and `muted` are distinct despite both being connected.

- [ ] **Step 2: Implement stable shell geometry**

Use fixed 56px status strip and 64px bottom navigation with safe-area additions. Content gets remaining space via `Expanded`; dynamic labels never resize navigation tracks.

- [ ] **Step 3: Implement truthful status actions**

Listening/muted opens device detail. Connecting offers cancel only if controller supports it. Offline opens diagnostics/reconnect. Bluetooth-off routes to explanatory Settings state. No fake toggle changes state before controller acknowledgement.

- [ ] **Step 4: Verify and commit**

```bash
cd mobile
flutter test test/widgets/app_shell_test.dart
flutter analyze
git add mobile/lib/widgets mobile/lib/main.dart mobile/test/widgets/app_shell_test.dart
git commit -m "feat: add global Echo navigation and status"
```

### Task 3: Four-Step Onboarding

**Files:**
- Create: `mobile/lib/screens/onboarding/onboarding_screen.dart`
- Create: `mobile/lib/screens/onboarding/welcome_step.dart`
- Create: `mobile/lib/screens/onboarding/backend_step.dart`
- Create: `mobile/lib/screens/onboarding/pairing_step.dart`
- Create: `mobile/lib/screens/onboarding/permissions_step.dart`
- Create: `mobile/lib/services/onboarding_controller.dart`
- Modify: `mobile/lib/main.dart`
- Test: `mobile/test/screens/onboarding_test.dart`

**Interfaces:**
- Steps: backend/API key validation → permissions explanation/request → wearable pairing → listening/mute explanation and finish.
- Onboarding completes only after authenticated backend, granted Bluetooth access, and saved wearable identity.
- Notification denial is allowed with visible degraded state; Bluetooth denial blocks pairing.

- [ ] **Step 1: Write failing flow tests**

Cover fresh install, backend validation failure/retry, Bluetooth/notification/background/voice-query microphone permission explanations, no-device scan/retry, pairing success, Bluetooth denial, notification denial, back navigation, app restart on each step, and completion persistence.

- [ ] **Step 2: Implement resumable controller**

Persist only the highest completed step, never secrets outside secure storage. Pairing delegates to `DeviceController.pair()`. Permission requests occur only after user taps the relevant CTA.

- [ ] **Step 3: Build the approved composition**

Use the mock's compact heading, progress dots, one primary action, optional secondary action, and live state text. The final step explains listening and app-controlled mute before completion. Onboarding occupies the usable viewport without decorative cards.

- [ ] **Step 4: Verify and commit**

```bash
cd mobile
flutter test test/screens/onboarding_test.dart
flutter analyze
git add mobile/lib/screens/onboarding mobile/lib/services/onboarding_controller.dart mobile/lib/main.dart mobile/test/screens/onboarding_test.dart
git commit -m "feat: add resumable Echo onboarding"
```

### Task 4: Today Privacy Surface

**Files:**
- Replace: `mobile/lib/screens/home_screen.dart`
- Create: `mobile/lib/widgets/privacy_control.dart`
- Create: `mobile/lib/widgets/today_memory_preview.dart`
- Test: `mobile/test/screens/today_screen_test.dart`

**Interfaces:**
- Listening CTA sends `setMuted(true)`; muted CTA sends `setMuted(false)`.
- Connecting/offline controls cannot claim a privacy transition that did not reach firmware.
- Recent memory preview opens Transcript detail.

- [ ] **Step 1: Write failing state matrix tests**

Render four device states in light/dark at 375×812. Assert exact primary copy, color, icon, action availability, progress state while awaiting acknowledgement, retry on command failure, and zero overlap at text scale 1.3.

- [ ] **Step 2: Implement privacy control**

Use a stable square/circular control region defined by constraints, not viewport-scaled typography. Haptics fire only after firmware status confirms the new mute state. Screen-reader live region announces confirmation/failure.

- [ ] **Step 3: Implement recent memory preview**

Show latest complete memory timestamp and excerpt. Empty/loading/error states keep the same geometry. A foreground upload completion refreshes through the existing transcript feed/controller, not an independent timer.

- [ ] **Step 4: Verify and commit**

```bash
cd mobile
flutter test test/screens/today_screen_test.dart
flutter analyze
git add mobile/lib/screens/home_screen.dart mobile/lib/widgets mobile/test/screens/today_screen_test.dart
git commit -m "feat: make wearable privacy the Today focus"
```

### Task 5: Transcript Memory Browse, Search, and Correction

**Files:**
- Replace: `mobile/lib/screens/transcripts_screen.dart`
- Modify: `mobile/lib/screens/transcript_detail_screen.dart`
- Create: `mobile/lib/models/transcript_group.dart`
- Create: `mobile/lib/services/transcript_controller.dart`
- Create: `mobile/lib/widgets/transcript_group_section.dart`
- Test: `mobile/test/services/transcript_controller_test.dart`
- Test: `mobile/test/screens/transcripts_screen_test.dart`

**Interfaces:**
- Groups are Today, Yesterday, then localized date.
- Search is debounced 300ms and stale responses cannot replace newer results.
- Detail exposes text/speaker edit and delete-conversation behavior from memory-controls plan.

- [ ] **Step 1: Write controller tests**

Cover grouping at local-midnight boundaries, stable chronological ordering, pagination merge/deduplication, search debounce, out-of-order responses, refresh after upload, and correction result replacement.

- [ ] **Step 2: Implement controller**

Keep raw API data immutable; derive groups and query state. Use a generation token to discard stale search results. Cancel timers/subscriptions on dispose.

- [ ] **Step 3: Write screen tests**

Cover empty/loading/error/list/search/no-result/detail/edit/delete states, keyboard inset, long transcript wrapping, speaker labels, and semantics traversal order.

- [ ] **Step 4: Build approved unframed timeline**

Use section labels and dividing rhythm instead of nested cards. Search expands in the header. Rows keep fixed metadata tracks while transcript text wraps naturally.

- [ ] **Step 5: Verify and commit**

```bash
cd mobile
flutter test test/services/transcript_controller_test.dart test/screens/transcripts_screen_test.dart
flutter analyze
git add mobile/lib mobile/test
git commit -m "feat: add searchable editable transcript memory"
```

### Task 6: Ask and Complete History

**Files:**
- Replace: `mobile/lib/screens/chat_screen.dart`
- Create: `mobile/lib/screens/chat_history_screen.dart`
- Create: `mobile/lib/services/chat_controller.dart`
- Create: `mobile/lib/widgets/chat_composer.dart`
- Test: `mobile/test/services/chat_controller_test.dart`
- Test: `mobile/test/screens/ask_screen_test.dart`

**Interfaces:**
- New Ask starts with suggestions and fixed composer.
- Text and voice input share the same composer; voice uses the existing `speech_to_text` dependency and always requires explicit user initiation.
- Selecting history loads complete session detail from the memory-controls plan.
- Session delete returns to refreshed history.

- [ ] **Step 1: Write controller tests**

Cover empty submit, typed submit, voice permission denial, voice start/stop and transcript submit, sending, streaming/non-streaming response compatibility, retry, session switch, complete-history load, stale request cancellation, delete, and citation navigation.

- [ ] **Step 2: Implement screen tests and UI**

Verify compact header/history icon, suggestion actions, keyboard-safe text/voice composer, message role semantics, long Markdown, citations, errors, and 44px microphone/send/history targets. External action confirmation UI remains hidden behind a disabled capability until the Composio phase; no fake actions are rendered. Do not put chat inside a decorative outer card.

- [ ] **Step 3: Verify and commit**

```bash
cd mobile
flutter test test/services/chat_controller_test.dart test/screens/ask_screen_test.dart
flutter analyze
git add mobile/lib mobile/test
git commit -m "feat: complete Ask and conversation history"
```

### Task 7: Hierarchical Settings and Device Detail

**Files:**
- Replace: `mobile/lib/screens/settings_screen.dart`
- Create: `mobile/lib/screens/device_detail_screen.dart`
- Create: `mobile/lib/screens/settings/appearance_settings_screen.dart`
- Create: `mobile/lib/screens/settings/network_settings_screen.dart`
- Create: `mobile/lib/screens/settings/backend_settings_screen.dart`
- Reuse: current Rules and Integrations screens/routes
- Test: `mobile/test/screens/settings_screen_test.dart`
- Test: `mobile/test/screens/device_detail_screen_test.dart`

**Interfaces:**
- Root rows under visual headers `DEVICE` and `ECHO`, in approved order: `DEVICE` contains Device, Connection, Privacy; `ECHO` contains Automations, Diagnostics, About.
- Rules and Integrations are nested under Automations; appearance, backend/network policy, retention/privacy, and logout live in their matching focused pages. Logout lives in About.
- Device detail: state, firmware/protocol version, buffer count/bytes, dropped count, muted state, reconnect, forget.
- Account logout delegates to `SessionController.logout()`.

- [ ] **Step 1: Write failing settings tests**

Assert exact root row order and `DEVICE`/`ECHO` grouping, route destinations, system/light/dark selection, cellular/Wi-Fi-only persistence, Rules/Integrations under Automations, diagnostics, backend edit validation, logout under About, logout confirm/error/success, and no unimplemented row.

- [ ] **Step 2: Write failing device-detail tests**

Cover listening/muted/connecting/offline, unknown battery omitted, buffer/dropped metrics, firmware version, reconnect, forget confirmation, forget success returning to pairing onboarding, and forget failure preserving identity.

- [ ] **Step 3: Implement unframed grouped settings**

Use full-width sections with dividers and disclosure chevrons. Switches only for true binary settings; segmented control for appearance; row commands for reconnect/forget/logout. Destructive commands use red only at the action point.

- [ ] **Step 4: Verify and commit**

```bash
cd mobile
flutter test test/screens/settings_screen_test.dart test/screens/device_detail_screen_test.dart
flutter analyze
git add mobile/lib/screens mobile/test/screens
git commit -m "feat: organize Echo settings and device detail"
```

### Task 8: Golden, Responsive, Accessibility, and Release Gate

**Files:**
- Create: `mobile/test/goldens/core_beta_golden_test.dart`
- Add: `mobile/test/goldens/baselines/*.png`
- Create: `mobile/test/accessibility/core_beta_semantics_test.dart`
- Create: `mobile/test/responsive/core_beta_layout_test.dart`

- [ ] **Step 1: Capture approved HTML references**

On the Mac, serve `docs/mockups/echo-mobile` and use Playwright to capture all 12 approved light/dark screen-state combinations at 375×812. Store these as review references outside Flutter's exact-pixel baselines because browser/Flutter rasterization differs.

- [ ] **Step 2: Add deterministic Flutter goldens**

Use fake controllers, bundled font loading, fixed locale/time, no active animations, and device pixel ratio 1. Capture Today four states × light/dark plus Transcripts, Ask, Settings, onboarding, and device detail.

- [ ] **Step 3: Add responsive matrix**

Pump every main screen at 320×568, 375×812, 390×844, and 430×932 with text scale 1.0 and 1.3. Assert no Flutter overflow exceptions, no horizontal scrolling except intended code/Markdown content, and stable bottom controls with keyboard inset.

- [ ] **Step 4: Add semantics matrix**

Assert every icon-only button has a label/tooltip, controls are ≥44×44, status changes use live regions, selected tab/state is announced, decorative elements are excluded, and destructive actions require confirmation.

- [ ] **Step 5: Run full verification**

```bash
cd mobile
flutter test
flutter analyze
flutter build ios --release --no-codesign
flutter build apk --debug
```

- [ ] **Step 6: Physical iPhone walkthrough**

Complete onboarding, background/lock relay, mute/unmute, search/edit/delete memory, Ask/history/delete, appearance switch, Wi-Fi-only behavior, diagnostics, forget/re-pair, and logout. Compare every screen to approved references and record intentional differences.

- [ ] **Step 7: Commit**

```bash
git add mobile/test
git commit -m "test: verify core beta mobile experience"
```

### Task 9: Core Beta Exit Review

**Files:**
- Modify documentation only for verified deviations.

- [ ] Re-run all device-reliability acceptance checks.
- [ ] Re-run all memory-controls acceptance checks.
- [ ] Run complete backend, firmware-native, and mobile suites plus release builds.
- [ ] Confirm no TODO/placeholder/unreachable control remains in the approved scope.
- [ ] Confirm forced-close recovery, Android background parity, battery sensing, microSD, Composio, and TestFlight remain explicitly deferred.
- [ ] Update the master spec only with accepted deviations and link the three completed plan outcomes.
