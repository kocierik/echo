# Echo Mobile App

Flutter companion app for the Echo Second Brain wearable.

## Setup

1. Install [Flutter](https://docs.flutter.dev/get-started/install) (3.x+)
2. Run:

```bash
cd mobile
flutter pub get
flutter run
```

## Configuration

On first launch, enter:
- **Server URL:** your Echo backend URL (e.g., `https://echo.example.com`)
- **API Key:** your Echo API key

## Features

- Chat with your memory (RAG query)
- Follow-up conversations (multi-turn)
- Session management (history, resume)
- Feedback on responses (👍/👎)
- Modern dark cinema UI

## Architecture

```
lib/
├── main.dart              # App entry, router
├── theme/
│   └── app_theme.dart     # Colors, typography, Material theme
├── services/
│   └── api_service.dart   # HTTP client, auth, API calls
├── screens/
│   ├── onboarding_screen.dart  # Server + key setup
│   └── chat_screen.dart        # Main chat + sessions
└── widgets/
    ├── message_bubble.dart     # Chat message component
    └── typing_indicator.dart   # Animated dots
```

## Design

Modern Dark Cinema style:
- Gradient background (#0a0a0f → #020203)
- Indigo accent (#5E6AD2)
- Borderless cards with subtle rgba borders
- System font (SF Pro / Roboto)
- Haptic feedback on interactions
