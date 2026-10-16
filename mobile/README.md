# Echo Mobile App

Flutter companion app for the Echo wearable, for iOS and Android. It relays audio
from the wearable over BLE to the backend and lets you browse, correct and query
your memory.

## Setup

1. Install [Flutter](https://docs.flutter.dev/get-started/install) (3.x+) and, for iOS, Xcode + CocoaPods;
   for Android, JDK 17 and the Android SDK (platform 36; Gradle fetches the NDK), then
   `flutter config --android-sdk <sdk> --jdk-dir <jdk>`.
2. Run:

```bash
cd mobile
flutter pub get
flutter run
```

### Native projects (`ios/`, `android/`)

Both are versioned; the bundle/application id is `com.kocierik.echo`. `ios/Runner/Info.plist` must
keep `UIBackgroundModes` → `bluetooth-central` and the Bluetooth, microphone and speech usage
descriptions. Set your signing team in Xcode; Android release signing is not configured yet
(`flutter build apk --debug` works, signed with the debug key).

On Android (`android/app/src/main/kotlin/com/kocierik/echo/`):

- **`EchoEngine.kt`** keeps one Flutter engine for the process: the activity borrows it and does
  not destroy it, so the Dart side (Bluetooth relay, uploads, commands) keeps running after the
  app leaves the screen or is swiped away from the recent apps.
- **`EchoStatusService.kt`** is a foreground service (type `connectedDevice`) with a silent
  notification: listening, muted or offline, battery and minutes waiting to sync. It is the
  `echo/live_activity` channel of iOS, always on while a wearable is paired, and what keeps
  Android from stopping the app in the background. Android 12+ starts it only while the app is
  on screen and Bluetooth is allowed; once started, updates in the background only change the
  notification.
- **`CalendarBridge.kt`** answers the `echo/eventkit` channel of iOS with the phone's calendar
  (CalendarContract). Android has no system Reminders app: reminders are unavailable, and
  Settings → On this phone offers the calendar only.
- The `echo/device` channel names the phone ("Google Pixel 8") and opens Echo's App info page.
- Scheduled notifications come back after a restart (`ScheduledNotificationBootReceiver`); they
  are inexact, so Android may deliver one a few minutes late.

## Configuration

On first launch the app shows a welcome and signs in with an Echo account (email and password,
made on the server with `make create-user`). Signing in gives this phone its own API key, kept in
the Keychain / Android Keystore; Settings → Devices signs it out or revokes other phones. Apple
and Google sign-in are shown and say they are coming.

The server address is built in: `https://echo.man.ovh` unless `dart_defines.json` (git-ignored, a
copy of `dart_defines.example.json`) says otherwise:

```bash
flutter run --dart-define-from-file=dart_defines.json
flutter build ios --dart-define-from-file=dart_defines.json
```

No key is ever compiled in. Settings → Server connection can point a development build elsewhere.

After signing in the app requests Bluetooth, notification and microphone permissions and pairs the
wearable. Without the wearable at hand, **I don't have it with me** finishes the setup; pair it
later from the device at the top of Settings. With a paired Echo, setup ends with a first voice
request ("Echo, remind me to …") and its answer.

## Features

- **Three tabs, Today | Ask | Memories**, with the round Ask button in the middle (hold it to dictate a
  question) and the device pill in every header (tap: Settings; long press: mute).
- **Today:** the device only when something is wrong (offline, not paired, Bluetooth off); **Needs
  you** with actions waiting for a Confirm (voice requests too); **To do today** (promises and tasks,
  at most three; the Tasks page from there); **Your day**, today's conversations on a timeline;
  **Echo can act in**, the connected apps. The daily and weekly summaries open Memories.
- **Memories:** conversations by day with emoji, title, summary, people and tasks (Live while
  Echo is still listening); search across titles, summaries, transcripts and extracted entities.
  The detail has a Summary (tasks with the sentence they came from, events with **Add to
  calendar**, ideas) and the Transcript, each line correctable; delete a conversation from its
  menu.
- **People:** everyone Echo heard about (Memories → People), by last seen; a person's page has
  their role and what Echo knows, open tasks and events naming them, the conversations they came
  up in, and **Ask about** them (a new chat with the question already sent).
- **Tasks:** open tasks by due day (Overdue, Today, Tomorrow, This week, Later, No date), complete
  with Undo, **Not a task** to drop a wrong one, open the conversation it came from; Done below.
- **Ask:** chat with your memory (text or voice) in any language; the answer appears while Echo
  writes it; sources say which conversation they come from and open it; suggestions come from
  your latest conversations and people; follow-ups, resumable history, feedback;
  requests to connected apps with Confirm/Cancel cards; the pinned **Voice requests**
  conversation collects answers to "Echo, …" requests spoken to the wearable.
- **Settings:** the device at the top (Mute Echo, Device details), Apps (Composio), On this iPhone,
  Activity, Notifications, Voices, Language (the language you speak: transcription and
  dictation), Appearance (System, Light, Dark), Privacy, What Echo can do,
  Server connection (Wi-Fi only uploads), Diagnostics, Devices (signed-in phones; connected apps:
  **Connect an assistant** gives Claude Code or Cursor a read-only key and the lines to paste;
  revoke either), About
  (sign out).
- BLE relay with automatic reconnect and iOS state restoration; local notifications
  for disconnection, audio loss, repeated upload failures and new voice-request answers
  (shown the next time the app wakes up).
- **On this iPhone** (Settings → On this iPhone): Echo creates and reads reminders and events in
  the iPhone's Reminders and Calendar when asked (EventKit, `ios/Runner/EventKit`), and the
  calendar's next meetings get briefings ([ADR 0010](../docs/adr/0010-iphone-reminders-and-calendar.md)).
- **Firmware updates** over Bluetooth (Settings → Device details, protocol 4): the latest firmware
  published on the server, checked by SHA-256 on the phone and on the wearable
  ([ADR 0009](../docs/adr/0009-firmware-updates-over-ble.md)).
- **Live Activity** (iOS 16.1+, `ios/EchoActivity` widget extension): listening, muted or
  offline, battery and minutes waiting to sync, on the lock screen and in the Dynamic Island.
  Updated locally by the app over the `echo/live_activity` channel (no push); off in
  Settings → Notifications. On Android the same channel drives the status notification, which
  cannot be turned off (see above).

## Architecture

```
lib/
├── main.dart          # App entry, router, onboarding gate
├── models/            # View state, chat, segments, device status
├── services/          # API client, BLE relay/protocol, controllers, notifications
├── screens/           # Today (home), Memories + conversation detail, Tasks, Ask (chat), Settings, onboarding
├── widgets/           # Shell, navigation, status strip, conversation card, task tile, shared sections, formatting
└── theme/             # Adaptive light/dark theme
```

The visual reference is `docs/mockups/echo-mobile/`.

## Tests

```bash
cd mobile
flutter test
```
