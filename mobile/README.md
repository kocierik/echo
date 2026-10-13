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

The native projects are versioned. If your checkout is missing them (they were
git-ignored before October 2026), regenerate the missing files once — `flutter create`
never overwrites existing files such as `ios/Runner/Info.plist` or
`android/app/src/main/AndroidManifest.xml`:

```bash
cd mobile
flutter create --platforms=ios,android --org <your.reverse.domain> --project-name echo_app .
```

Then check that `ios/Runner/Info.plist` still declares `UIBackgroundModes` →
`bluetooth-central` and the Bluetooth/microphone/speech usage descriptions, set the
signing team in Xcode, and commit the generated `ios/` and `android/` files.

## Configuration

On first launch the onboarding asks for:
- **Server URL:** your Echo backend URL (e.g., `https://echo.example.com`)
- **API Key:** your Echo API key

then requests Bluetooth, notification and microphone permissions and pairs the wearable.

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
