# Transcript translation: hear other languages, read them in yours

Date: 2026-10-28. Point 4 of `next-step` ("traduttore live"), as the user clarified it: "dare
la possibilità di tradurre il testo ascoltato nella app dopo che è stata fatta la
trascrizione. Dovremmo riconoscere in quale lingua si sta parlando." The user asked to
proceed without a design round ("procedi con 4 anche"), so the decisions below are the
builder's calls unless quoted.

## Intent

Echo transcribes in the account's language (`users.language`, `it` or `en`), passed to the
speech-to-text as a fixed language. A conversation in another language (a colleague in
English, a holiday in Spain) comes out wrong or half-translated, and the user cannot read
it in their own language. Two parts:

1. **Recognise the language spoken**, so the transcript is what was said.
2. **Translate it in the app**, after the transcription, into the user's language.

## Goals

- Profile → Language keeps "the language you speak" (`en`/`it`, unchanged) and adds
  **"Other languages you hear"**: up to 4 of English, Italiano, Español, Français,
  Deutsch, Português (not the main one). Kept on the account (`users.other_languages`).
  Default: none, so nothing changes for whoever does not set it (call: language
  detection on short clips is less accurate than a fixed language; only people who
  hear other languages pay that).
- With other languages set, the speech-to-text recognises which of the account's
  languages each segment is in and transcribes it in that language:
  - Deepgram (the server's provider): `detect_language` restricted to those languages;
    the detected language is stored on the transcription (`transcriptions.language`,
    already there). If Deepgram refuses keyterms together with detection (HTTP 400), the
    request is retried once without keyterms.
  - OpenAI: `gpt-transcribe` / `gpt-live-transcribe` get the list as `languages`;
    `whisper-1` gets no hint and reports the language of its `verbose_json`; other
    models get no hint and report the main language (call: no detection there; this
    server uses Deepgram).
- A conversation's lines (`GET /api/conversations/{id}`) carry their `language`.
- **Translate**: on a conversation with at least one line in a language other than the
  user's, the transcript shows "Translate to Italiano" (or English). A tap shows, under
  each such line, its translation; another tap ("Hide translation") hides them. Lines
  already in the user's language are not translated.
- `POST /api/conversations/{id}/translate` translates those lines into the account's
  language with the LLM, in one call per batch of lines, and keeps each translation
  (`transcription_translations`: one per transcription and target language), so a
  second tap costs nothing. Correcting a line's text drops its translations.
- Each foreign line shows a small language tag ("EN") next to the time.

## Non-goals

- Live (word by word) translation while people speak; translating spoken answers.
- Translating summaries, tasks or memory: they stay as the analysis wrote them.
- Translating into a language other than the account's.
- More languages than the six listed.

## Anti-goals

- A user who never sets other languages gets a worse transcription.
- Echo transcribes a segment in the user's language as a foreign one and offers to
  translate what is already readable.
- A translation silently replaces the original: the original is always shown.

## Constraints

- FastAPI + SQLAlchemy async + Alembic (next migration 027), pytest via podman; Flutter
  app in `mobile/`.
- Account languages stay `en`/`it` for the main language (dictation, UI).

## Left to the builder

Names, the LLM prompt, batch size, where the button sits in the transcript.
