# Echo Mobile App

Flutter companion app for the Echo wearable (iOS-first core beta). It relays audio
from the wearable over BLE to the backend and lets you browse, correct and query
your memory.

## Setup

1. Install [Flutter](https://docs.flutter.dev/get-started/install) (3.x+) and, for iOS, Xcode + CocoaPods.
2. Run:

```bash
cd mobile
flutter pub get
flutter run
```

### Native projects (`ios/`, `android/`)

Both are versioned; the bundle/application id is `com.kocierik.echo`. `ios/Runner/Info.plist` must
keep `UIBackgroundModes` → `bluetooth-central` and the Bluetooth, microphone and speech usage
descriptions. Set your signing team in Xcode; Android release signing is not configured yet.

## Configuration

On first launch the onboarding asks for:
- **Server URL:** your Echo backend, prefilled with `https://echo.man.ovh`
- **API Key:** your Echo API key

Both can be compiled in so the onboarding only needs a tap on Continue. Copy
`dart_defines.example.json` to `dart_defines.json` (git-ignored), put your key in it and run:

```bash
flutter run --dart-define-from-file=dart_defines.json
flutter build ios --dart-define-from-file=dart_defines.json
```

A key compiled in can be read from the app binary: keep such builds for your own devices.

The onboarding then requests Bluetooth, notification and microphone permissions and pairs the
wearable. Without the wearable at hand, **Skip for now** finishes the setup; pair it later from
Settings → Device → **Pair Echo**.

## Features

- **Today:** wearable status, latest transcripts, open tasks, daily summary, pause/resume.
- **Transcripts:** grouped by day, searchable; edit text and speaker, delete a conversation.
- **Ask:** chat with your memory (text or voice), follow-ups, resumable history, feedback;
  requests to connected apps with Confirm/Cancel cards; the pinned **Voice requests**
  conversation collects answers to "Echo, …" requests spoken to the wearable.
- **Settings:** device, connection policy (Wi-Fi only), privacy, Automations (Integrations
  through Composio and the Activity log), diagnostics, appearance, logout.
- BLE relay with automatic reconnect and iOS state restoration; local notifications
  for disconnection, audio loss, repeated upload failures and new voice-request answers
  (shown the next time the app wakes up).

## Architecture

```
lib/
├── main.dart          # App entry, router, onboarding gate
├── models/            # View state, chat, segments, device status
├── services/          # API client, BLE relay/protocol, controllers, notifications
├── screens/           # Today (home), Transcripts, Ask (chat), Settings, onboarding
├── widgets/           # Shell, navigation, status strip, message bubble, ...
└── theme/             # Adaptive light/dark theme
```

The visual reference is `docs/mockups/echo-mobile/`.

## Tests

```bash
cd mobile
flutter test
```
