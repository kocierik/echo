# Spoken answers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone reads Echo's voice answers aloud, in headphones or on the speaker, also in the background.

**Architecture:** `VoiceUpdatesService` hands each new answer to an `AnswerSpeaker`, which applies the Profile setting, turns markdown into speech text, queues answers, mutes the wearable while speaking on the speaker and speaks through `flutter_tts`. Headphones come from a native `headphones` method on the `echo/device` channel.

**Tech Stack:** Flutter (Dart 3), flutter_tts 4.2.5, Swift (AVAudioSession), Kotlin (AudioManager).

**Spec:** docs/superpowers/specs/2026-10-28-spoken-answers-design.md

## Global Constraints

- Setting values: `off`, `headphones`, `always`; prefs key `spoken_answers`; default `off`.
- Cut near 500 characters at a sentence end; tail "The rest is in Ask." (en) / "Il resto è in Ask." (it).
- TTS languages: `it` → `it-IT`, anything else → `en-US`.
- Mute flag prefs key `spoken_answers_muted_echo`.
- Commit `pubspec.lock` with only the `flutter_tts` entry.
- Code, comments and commits in English; commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- An answer arriving while another is spoken: both are spoken, in order, never at once.
- The wearable muted by the user before an answer: it stays muted after it.
- The app killed while speaking on the speaker: the next start unmutes Echo.
- Holding Ask while an answer is spoken: speech stops and queued answers are dropped.
- A failing TTS engine or headphones check: no exception escapes into voice updates.

---

### Task 1: Speech text

**Files:** Create `mobile/lib/utils/spoken_text.dart`; Test `mobile/test/utils/spoken_text_test.dart`.

**Interfaces:** Produces `String spokenText(String markdown, {required String language, int limit = 500})`.

- [ ] Tests: markdown marks (`**`, `#`, `` ` ``, `- `/`• ` bullets, `[title](url)` → `title`, bare `https://…` dropped) become plain text with one sentence/line per line kept as ". "-free spacing; a 1200-char answer is cut at the last `.`/`!`/`?` before 500 and ends with the language's tail; without a sentence end it is cut at a word; `it` uses the Italian tail.
- [ ] Watch them fail, implement, watch them pass, commit.

### Task 2: The setting

**Files:** Create `mobile/lib/services/app/spoken_answers_store.dart`, `mobile/lib/screens/settings/spoken_answers_screen.dart`; Modify `mobile/lib/screens/profile_screen.dart`; Tests `mobile/test/services/spoken_answers_store_test.dart`, `mobile/test/screens/spoken_answers_screen_test.dart`.

**Interfaces:** Produces `enum SpokenAnswers { off, headphones, always }`; `final class SpokenAnswersStore extends ValueNotifier<SpokenAnswers>` with `SpokenAnswersStore(SharedPreferences)`, `Future<void> set(SpokenAnswers)`; `SpokenAnswersScreen({required SpokenAnswersStore store, required Future<void> Function() onTry})` with keys `spoken-answers-control`, `spoken-answers-try`.

- [ ] Tests: default off; unknown stored value → off; `set` saves and notifies; the screen shows the three choices, a tap saves, "Try it" calls `onTry`; Profile shows a "Spoken answers" row (key `profile-spoken-answers`) whose subtitle says the choice.
- [ ] RED, implement, GREEN, commit.

### Task 3: AnswerSpeaker

**Files:** Create `mobile/lib/services/phone/answer_speaker.dart`; Test `mobile/test/services/answer_speaker_test.dart`.

**Interfaces:** Produces ports `abstract interface class AnswerVoice { Future<void> speak(String text, String language); Future<void> stop(); }`, `abstract interface class AudioOutput { Future<bool> headphones(); }`, `abstract interface class EchoMic { bool get listening; Future<void> setMuted(bool muted); }`; `final class AnswerSpeaker` with `AnswerSpeaker({required AnswerVoice voice, required AudioOutput output, required ValueListenable<SpokenAnswers> setting, required SharedPreferences preferences, required String Function() language, EchoMic? mic})`, `Future<void> say(String answer)`, `Future<void> stop()`, `Future<void> recover()`, `static const mutedKey = 'spoken_answers_muted_echo'`.

- [ ] Tests: off → nothing spoken; headphones setting without headphones → nothing; with → spoken via `spokenText` in the language; always on the speaker with Echo listening → mute, speak, unmute, flag set during and cleared after; Echo already muted → never touched; with headphones → never muted; two `say` calls → spoken in order, the second after the first completes; `stop` stops and drops the queue; a voice that throws → Echo unmuted, no exception out, next answer still spoken; `recover` with the flag set unmutes and clears it, and keeps it when unmuting throws.
- [ ] RED, implement, GREEN, commit.

### Task 4: Wiring and native

**Files:** Modify `mobile/lib/services/chat/voice_updates_service.dart`, `mobile/lib/services/app/app_lifecycle_coordinator.dart`, `mobile/lib/main.dart` (or wherever the Profile screen and dictation are wired), `mobile/pubspec.yaml`, `mobile/ios/Runner/AppDelegate.swift`, `mobile/ios/Runner/Info.plist`, `mobile/android/app/src/main/kotlin/com/kocierik/echo/EchoEngine.kt`, `mobile/android/app/src/main/AndroidManifest.xml`; Create adapters `FlutterTtsVoice`, `ChannelAudioOutput`, `DeviceEchoMic` in `answer_speaker.dart`. Test `mobile/test/services/voice_updates_service_test.dart`.

**Interfaces:** Consumes Task 3. `VoiceUpdatesService(..., void Function(String answer)? onNewAnswer)`.

- [ ] Test: each new assistant answer is passed whole to `onNewAnswer`, once (not again when seen), never for routine runs. RED, implement, GREEN.
- [ ] Wire: coordinator builds the speaker, calls `recover()` at start and on resume; dictation (`askDictation` true) calls `stop()`; Profile gets the store and "Try it".
- [ ] Native: iOS `headphones` (current route outputs: headphones, bluetoothA2DP, bluetoothHFP, bluetoothLE, usbAudio), `audio` in `UIBackgroundModes`; Android `headphones` (AudioManager output devices: wired headset/headphones, Bluetooth A2DP/SCO, USB headset, BLE headset on API 31+) and the `TTS_SERVICE` query.
- [ ] `flutter analyze` clean, full suite green, commit.

### Task 5: Docs

- [ ] README / PROJECT-STATUS / ROADMAP: spoken answers, where the setting is, what it does on the speaker. Commit.
