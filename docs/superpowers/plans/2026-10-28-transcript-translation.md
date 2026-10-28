# Transcript Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Echo recognises which of the user's languages a segment is in, and the app translates foreign lines of a conversation into the user's language.

**Architecture:** The account gets `other_languages`; the STT worker passes the main and other languages to the provider, which detects among them and reports the language stored on the transcription. A translate endpoint translates a conversation's foreign lines with the LLM and caches them per transcription and language; the conversation page shows them under the originals.

**Tech Stack:** FastAPI, SQLAlchemy async, Alembic, Deepgram REST, OpenAI SDK, Flutter.

**Spec:** docs/superpowers/specs/2026-10-28-transcript-translation-design.md

## Global Constraints

- Heard languages: `en`, `it`, `es`, `fr`, `de`, `pt`; at most 4 others, never the main one; default `[]`.
- Migration `027`; table `transcription_translations` (unique `transcription_id`, `language`), `users.other_languages` JSONB not null default `[]`.
- Detected codes are reduced to their base (`en-US` → `en`); anything outside the account's languages falls back to the main language.
- Code, comments, commits in English; commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- A user with no other languages: the STT request is exactly as before (single `language`).
- Deepgram detects a language not in the account's list, or none: the main language is stored.
- A conversation whose lines are all in the user's language: no Translate button, and the endpoint translates nothing.
- A line corrected after it was translated: its old translation is never shown again.
- The LLM answers with fewer lines, extra text or bad JSON: no crash; lines without a translation are left untranslated.

---

### Task 1: Data

**Files:** Create `backend/alembic/versions/027_transcript_translation.py`, `backend/app/models/transcription_translation.py`; Modify `backend/app/models/user.py`, `backend/app/models/__init__.py` (if models are registered there), `backend/tests/test_migrations.py`.

- [ ] Test (migrations): 027 adds `users.other_languages` (default `[]`) and `transcription_translations` with its unique pair and cascade from `transcriptions`; downgrade removes them; the chain test covers 027.
- [ ] RED, implement, GREEN, commit.

### Task 2: Account languages

**Files:** Modify `backend/app/routers/auth.py`, `backend/app/services/language.py`; Test `backend/tests/test_auth_me.py` (or the existing `/me` test file).

**Interfaces:** Produces `HEARD_LANGUAGES = ("en", "it", "es", "fr", "de", "pt")`, `async def account_languages(db, user_id) -> tuple[str, list[str]]` (main, others). `Me.other_languages: list[str]`; `MeUpdate.other_languages: list[str] | None`.

- [ ] Tests: `/me` returns `other_languages: []`; PATCH keeps order, drops duplicates and the main language, refuses a code outside `HEARD_LANGUAGES` or more than 4 (422); changing the main language drops it from the others.
- [ ] RED, implement, GREEN, commit.

### Task 3: Recognising the language

**Files:** Modify `backend/app/services/stt_base.py`, `stt_deepgram.py`, `stt_openai.py`, `backend/app/workers/stt.py`; Tests `backend/tests/test_stt_deepgram.py`, `test_stt_openai.py` (existing or new), worker test.

**Interfaces:** `STTService.transcribe(audio_data, language="it", prompt=None, keyterms=None, also: list[str] | None = None) -> STTResult` where `STTResult.language` is the detected base code.

- [ ] Tests (Deepgram, with its fake transport): no `also` → params as before (`language=it`); with `also=["en"]` → `detect_language=it`, `detect_language=en`, no `language`, and `detected_language: "en-US"` → `"en"`; a detected language outside the list → main; a 400 with keyterms → retried once without, then succeeds.
- [ ] Tests (OpenAI, fake client): `gpt-transcribe` gets `languages=[main, *also]`; `whisper-1` with `also` gets no `language` and maps `"english"` → `en`; `gpt-4o-transcribe` with `also` gets no hint and reports main.
- [ ] Worker test: the user's other languages reach `transcribe(also=...)` and the detected language is stored on the transcription.
- [ ] RED, implement, GREEN, commit.

### Task 4: Translate

**Files:** Create `backend/app/services/transcript_translation.py`; Modify `backend/app/routers/conversations.py` (lines' `language`; `POST /{id}/translate`), the transcription edit path (drop translations on a text change); Test `backend/tests/test_transcript_translation.py`.

**Interfaces:** `POST /api/conversations/{id}/translate` → `{"language": "it", "lines": {"<segment_id>": "<text>"}}` for the lines not in the account's language. `TranscriptionOut.language: str | None`.

- [ ] Tests: lines carry `language`; translate returns only foreign lines, in the account's language, calling the LLM once for them; a second call uses the stored ones (no LLM call); all-native conversation → `{}` and no LLM call; a corrected line is translated again; LLM bad JSON or missing items → those lines absent, 200; someone else's conversation → 404.
- [ ] RED, implement, GREEN, commit.

### Task 5: App

**Files:** Modify `mobile/lib/services/app/spoken_language.dart` (AccountInfo.otherLanguages, API), `mobile/lib/screens/settings/language_settings_screen.dart`, the conversation model (`TranscriptLine.language`), the API service (translate), the conversation screen; Tests for each.

- [ ] Tests: Language page shows the other languages as chips (main one absent), a tap saves the list; a conversation with a foreign line shows the "EN" tag and "Translate to Italiano"; a tap shows translations under those lines, "Hide translation" hides them; an all-native conversation shows no button; a failing translate says so.
- [ ] RED, implement, GREEN, analyze clean, commit.

### Task 6: Docs

- [ ] README (API + feature), PROJECT-STATUS, ROADMAP (#4 done), DEVELOPMENT if STT notes change. Commit.
