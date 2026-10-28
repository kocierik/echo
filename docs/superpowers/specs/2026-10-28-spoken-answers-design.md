# Spoken answers: Echo answers aloud through the phone

Date: 2026-10-28. The user asked for it ("usare l'altoparlante del telefono per comunicare
con echo, in modo che ci possa rispondere") and chose to skip the design questions ("io
partirei subito"), so every decision below is the builder's call unless marked as theirs.

## Intent

Today a voice request ("Echo, che tempo fa domani?") is answered in the thread with Echo
and as a notification: the user has to take the phone out and read it. With spoken
answers the phone reads the answer aloud, in headphones or on the speaker, also with the
app in the background, so a request made by voice gets its answer by voice.

## Goals

- The answers that are notified today as voice answers (new assistant messages found by
  `VoiceUpdatesService`) are also spoken, one after the other, in the order they arrive.
- It works with the app in the background and the screen locked (iOS: the `audio`
  background mode; Android: the existing foreground service keeps the engine alive).
- A setting in Profile, "Spoken answers": **Off**, **With headphones** (only when
  headphones, AirPods or another Bluetooth audio output are connected), **Always** (also
  on the speaker). Kept on the phone. Default **Off** (call: nothing speaks out loud
  after an update without the user choosing it).
- "Try it" on that page speaks a sample sentence with the current choice.
- What is spoken: the answer as plain speech, without markdown marks or links; a long
  answer is cut at a sentence end near 500 characters and followed by "The rest is in
  Ask." / "Il resto è in Ask.".
- The voice speaks the user's language (the account's spoken language, `en` or `it`,
  kept on the phone by `SpokenLanguageStore`).
- Other audio (music, a podcast) is lowered while Echo speaks, then comes back.
- On the speaker, Echo (the wearable) is muted while the phone speaks and unmuted after,
  so it does not record and transcribe its own answer. Only when it was listening
  before; never unmuted if the user had muted it. If the app dies mid-answer, the next
  start unmutes it (a flag kept on the phone).
- Holding the Ask button (dictation) stops any answer being spoken and clears the queue.

## Non-goals

- Routine results are not spoken (call: they come at a scheduled time, often when the
  user is not expecting a voice).
- Answers to questions typed in Ask are not spoken (they are on screen already).
- No server change, no cloud voice: the phone's own text-to-speech (`flutter_tts`), free
  and offline. A nicer server voice can come later.
- No voice picker or speed setting.

## Anti-goals

- The phone starts talking on the speaker in a meeting without the user having chosen
  "Always".
- Echo stays muted after speaking.
- Echo transcribes the phone's voice as a conversation.

## Constraints

- Flutter app in `mobile/`; native code in `ios/Runner/AppDelegate.swift` (the
  `echo/device` channel) and `android/.../EchoEngine.kt` (same channel).
- Headphones are detected natively: a `headphones` method on `echo/device` returning a
  bool; an error or a missing method counts as no headphones.
- `pubspec.lock` changes only by the `flutter_tts` entry.

## Left to the builder

Names, file layout, how the queue is built, the exact markdown stripping.
