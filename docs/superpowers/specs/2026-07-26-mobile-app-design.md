# Echo Mobile App — Design Spec

## Goal

Flutter mobile app for querying personal memory on the go. Connects to the existing Echo backend API.

## Scope MVP

- Chat screen (RAG query + follow-up sessions)
- Onboarding (server URL + API key)
- Session list (previous chats)
- Typing indicator + feedback (👍/👎)

## Tech Stack

- Flutter 3.x + Dart
- Material 3 dark theme (heavily customized)
- `http` / `dio` for API calls
- `shared_preferences` for server URL
- `flutter_secure_storage` for API key

## Design System — "Modern Dark Cinema"

### Palette

| Token | Value | Usage |
|-------|-------|-------|
| bg-deep | #020203 | Screen background (gradient bottom) |
| bg-base | #0a0a0f | Screen background (gradient top) |
| bg-elevated | #0a0a0c | Cards, message bubbles, input |
| surface | rgba(255,255,255,0.05) | Pressed states, subtle hover |
| foreground | #EDEDEF | Primary text |
| foreground-muted | #8A8F98 | Secondary text, timestamps |
| accent | #5E6AD2 | User messages, links, CTA |
| accent-glow | rgba(94,106,210,0.2) | Glow behind accent elements |
| border | rgba(255,255,255,0.08) | Card borders, separators |
| success | #30D158 | Online indicator, positive feedback |
| error | #FF453A | Errors |

### Typography

- Font: system default (San Francisco on iOS, Roboto on Android)
- Headline: weight 600, size 20, tracking -0.02em
- Body: weight 400, size 15
- Caption: weight 400, size 12, color foreground-muted

### Components

- Border radius: 16px (cards), 12px (buttons), 24px (input pill)
- Easing: Curves.easeOutExpo (cubic-bezier 0.16, 1, 0.3, 1)
- No shadows — borders only (rgba white 0.08)
- Background: LinearGradient top #0a0a0f → bottom #020203
- Messages user: accent bg, white text, right-aligned, borderRadius 20/20/4/20
- Messages assistant: bg-elevated, border, left-aligned, borderRadius 4/20/20/20
- Input: pill shape, bg-elevated, border, send icon right

### Screen Architecture

```
App
├── SplashScreen (brief, auto-navigate)
├── OnboardingScreen (server URL + API key)
└── MainScreen
    ├── AppBar (Echo + dot + sessions icon)
    ├── ChatBody (messages list, scrollable)
    ├── TypingIndicator (3 dots, animated)
    └── InputBar (text field + send button, pill)

SessionsSheet (bottom sheet with list of previous chats)
```

### Animations

- Message appear: slide up + fade in (200ms, easeOutExpo)
- Typing dots: 3 circles, staggered opacity pulse
- Send button: scale press 0.95 → 1.0 with haptic
- Session sheet: bottom sheet with spring animation

### UX Rules

- Keyboard pushes input bar up (resizeToAvoidBottomInset)
- Auto-scroll to bottom on new message
- Long-press message to copy
- Pull-to-refresh for session reload
- Haptic on send and feedback tap
