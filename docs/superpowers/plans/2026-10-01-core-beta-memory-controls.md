# Core Beta Memory Controls Implementation Plan

> **Stato (13/10/2026): implementato** — commit 52ad9e6. Le checkbox qui sotto non sono state aggiornate durante l'implementazione; lo stato attuale è in [PROJECT-STATUS.md](../../PROJECT-STATUS.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the personal beta truthful, reversible control over stored memories: complete chat history, auditable transcript/speaker corrections with semantic reanalysis, 24-hour audio deletion, 7-day incomplete-audio retention, and complete conversation deletion.

**Architecture:** FastAPI owns all data mutation and audit rules. Corrections are synchronous database writes followed by an idempotent Redis reanalysis job. Reanalysis shares entity/embedding code with initial analysis but has no route to integration or Rules side effects. PostgreSQL cascade constraints define deletion correctness; mobile only reflects API outcomes.

**Tech Stack:** FastAPI, Pydantic, SQLAlchemy async, Alembic, PostgreSQL/pgvector, Redis, pytest, Flutter/Dart.

## Global Constraints

- Execute after the device-reliability plan gate.
- Preserve `POST /api/segments` and existing query/chat contracts.
- A correction must never trigger Rules or external integrations.
- Correction HTTP success means text/speaker plus audit row committed; reanalysis may be pending.
- Correction response is `202 Accepted` with `reanalysis_status="queued"`.
- Reanalysis must be retry-safe and converge to current transcription state.
- Completed audio expires after 24 hours; pending, processing, and failed audio expires after 7 days. Segment/transcription metadata remains until conversation deletion.
- Deleting a conversation removes Segments, transcriptions, entities, embeddings, relationships, and correction audit through database cascades.
- API-key authorization scopes every read/update/delete.
- Logout clears API key, saved wearable ID, cached UI state, and active BLE work; it does not delete server data.
- Do not add multi-user account management, transcript history restoration UI, bulk export, or cloud audio archive.

---

### Task 1: Lifecycle Schema and Cascade Migration

**Files:**
- Create: `backend/alembic/versions/006_memory_lifecycle.py`
- Modify: `backend/app/models/transcription.py`
- Modify: `backend/app/models/conversation.py`
- Modify: `backend/app/models/segment.py`
- Modify: `backend/app/models/entity.py`
- Create: `backend/app/models/transcription_edit.py`
- Modify: `backend/app/models/__init__.py`
- Test: `backend/tests/test_memory_lifecycle_schema.py`

**Interfaces:**
- Produces table `transcription_edits(id, transcription_id, user_id, old_text, new_text, old_speaker_label, new_speaker_label, created_at)`.
- `transcription_edits.transcription_id`, `segments.conversation_id`, and `entities.conversation_id` use `ON DELETE CASCADE`.
- Existing `chunks.conversation_id ON DELETE CASCADE` is preserved and covered by the schema test.

- [ ] **Step 1: Write failing metadata tests**

```python
def test_transcription_edit_is_registered():
    table = Base.metadata.tables["transcription_edits"]
    assert set(table.columns) == {
        "id", "transcription_id", "user_id", "old_text", "new_text",
        "old_speaker_label", "new_speaker_label", "created_at",
    }

def test_conversation_children_use_database_cascade():
    assert Conversation.segments.property.passive_deletes is True
    assert Conversation.entities.property.passive_deletes is True
    assert Conversation.chunks.property.passive_deletes is True
    assert next(iter(Segment.__table__.c.conversation_id.foreign_keys)).ondelete == "CASCADE"
    assert next(iter(Entity.__table__.c.conversation_id.foreign_keys)).ondelete == "CASCADE"
    assert next(iter(Chunk.__table__.c.conversation_id.foreign_keys)).ondelete == "CASCADE"
    assert next(iter(TranscriptionEdit.__table__.c.transcription_id.foreign_keys)).ondelete == "CASCADE"
```

Run `cd backend && pytest tests/test_memory_lifecycle_schema.py -q`; expect failure.

- [ ] **Step 2: Add ORM model and relationships**

Use UUID primary keys, timezone-aware `created_at`, nullable old/new speaker labels, non-null old/new text, and indexed transcription/user IDs. Set relationship cascades consistently with database ownership and `passive_deletes=True` at Conversation.

- [ ] **Step 3: Write reversible Alembic migration**

Inspect current foreign-key names before dropping them. Segment→Conversation currently has no delete action and Entity→Conversation uses `SET NULL`; recreate both with `ondelete="CASCADE"`. Preserve the existing Chunk→Conversation cascade, create the audit table and indexes, and make downgrade restore the two prior FK behaviors.

- [ ] **Step 4: Verify migration**

```bash
cd backend
pytest tests/test_memory_lifecycle_schema.py -q
alembic upgrade head
alembic downgrade 005
alembic upgrade head
```

- [ ] **Step 5: Commit**

```bash
git add backend/alembic backend/app/models backend/tests/test_memory_lifecycle_schema.py
git commit -m "feat: add memory lifecycle schema"
```

### Task 2: Typed Mobile API Errors and Logout

**Files:**
- Create: `mobile/lib/services/api_exception.dart`
- Modify: `mobile/lib/services/api_service.dart`
- Modify: `mobile/lib/services/device_controller.dart`
- Create: `mobile/lib/services/session_controller.dart`
- Test: `mobile/test/services/api_service_test.dart`
- Test: `mobile/test/services/session_controller_test.dart`

**Interfaces:**
- `ApiException(statusCode, code, message, retryable)`.
- Every HTTP method has connect/read timeout and checks expected status explicitly.
- `SessionController.logout()` stops BLE, clears secure key/device identity/preferences, then emits logged-out.

- [ ] **Step 1: Write failing HTTP behavior tests**

Use an injected `http.Client`. Cover malformed JSON, 401, 404, 409, 422, 500, timeout, and expected 200/201/202/204. Assert no method silently returns `false` for a transport/server failure.

- [ ] **Step 2: Centralize request decoding**

Implement one `_send` helper returning decoded JSON or throwing `ApiException`. Apply `.timeout(const Duration(seconds: 10))` to every request Future, map `TimeoutException`, 408, 429, and 5xx to retryable, and preserve endpoint-specific expected statuses.

- [ ] **Step 3: Write and implement logout ordering test**

Assert BLE stop occurs before stores are cleared, every store is attempted even if one clear fails, and final state reports any cleanup error without retaining the API key.

- [ ] **Step 4: Verify and commit**

```bash
cd mobile
flutter test test/services/api_service_test.dart test/services/session_controller_test.dart
flutter analyze
git add mobile/lib/services mobile/test/services
git commit -m "feat: make session and API failures explicit"
```

### Task 3: Complete Chat Session History

**Files:**
- Modify: `mobile/lib/models/chat_session.dart`
- Modify: `mobile/lib/services/api_service.dart`
- Modify: `mobile/lib/screens/chat_screen.dart`
- Test: `mobile/test/models/chat_session_test.dart`
- Test: `mobile/test/screens/chat_screen_test.dart`

**Interfaces:**
- Produces `ChatSessionDetail` with ordered `ChatMessage` values.
- `ApiService.getSessionDetail(String id)` calls existing `GET /api/chat-sessions/{id}`.
- `ApiService.deleteSession(String id)` calls existing DELETE endpoint.

- [ ] **Step 1: Write failing model/parser tests**

Use a fixture containing user/assistant roles, citations, timestamps, and null optional fields. Assert message order matches the backend response.

- [ ] **Step 2: Implement detail/delete API methods**

Expect 200 for detail and 204 for delete. Throw typed 404 instead of rendering an empty session.

- [ ] **Step 3: Replace the placeholder loader**

`ChatScreen._loadSession()` renders loading, complete messages, empty, not-found, and retryable error states. Delete confirms once, calls API, then returns to history and refreshes it.

- [ ] **Step 4: Verify and commit**

```bash
cd mobile
flutter test test/models/chat_session_test.dart test/screens/chat_screen_test.dart
flutter analyze
git add mobile/lib mobile/test
git commit -m "feat: load complete Ask history"
```

### Task 4: Audited Transcript Correction Endpoint

**Files:**
- Modify: `backend/app/routers/segments.py`
- Create: `backend/app/schemas/transcription.py`
- Create: `backend/app/services/transcription_editor.py`
- Create: `backend/tests/test_transcription_correction.py`

**Interfaces:**
- `PATCH /api/segments/{segment_id}/transcription`.
- Request: `{ "text": string, "speaker": "self" | "other" | "unknown" }`; text is always required and non-empty.
- Response 202: `{segment_id, transcription_id, text, speaker_label, updated_at, reanalysis_status}`.
- Redis payload: `{conversation_id, requested_at}` on `queue:reanalysis`.

- [ ] **Step 1: Write failing endpoint tests**

Cover text correction, speaker correction with the current full text, both, empty text 422, invalid speaker 422, foreign user 404, absent transcription 409, unchanged values as 200/no audit/no job, and queue failure after commit returning 202 with `reanalysis_status="queue_failed"` plus an error log.

- [ ] **Step 2: Implement transactional editor**

Lock the Segment/transcription row, verify `segment.user_id`, store one immutable audit row, update transcription text/speaker plus the Segment speaker label, set the Conversation to `analysis_status="reprocessing"`, commit once, then enqueue after commit. Empty strings are invalid; trimmed non-empty text is accepted.

- [ ] **Step 3: Add router and response schema**

Use current API-key dependency. Do not leak whether another user's Segment exists.

- [ ] **Step 4: Verify and commit**

```bash
cd backend
pytest tests/test_transcription_correction.py -q
git add backend/app backend/tests/test_transcription_correction.py
git commit -m "feat: audit transcript corrections"
```

### Task 5: Side-Effect-Free Reanalysis Worker

**Files:**
- Create: `backend/app/services/analysis_pipeline.py`
- Create: `backend/app/services/conversation_reanalysis.py`
- Modify: `backend/app/workers/main.py`
- Create: `backend/tests/test_conversation_reanalysis.py`
- Modify: `backend/tests/test_worker_pipeline.py`

**Interfaces:**
- `AnalysisPipeline.analyze_text(..., allow_side_effects: bool)`.
- Normal Segment processing always passes `allow_side_effects=True`.
- Reanalysis always passes `allow_side_effects=False`.
- `reanalyse_conversation(conversation_id)` rebuilds derived entities/embeddings/summary from current transcriptions.

- [ ] **Step 1: Write characterization tests around current worker**

Before extraction, freeze the existing successful call order: transcription grouping, entity extraction, embeddings, integrations, Rules. This disconfirms accidental behavior changes during refactor.

- [ ] **Step 2: Extract analysis pipeline without changing behavior**

Move reusable extraction, summary, and embedding orchestration out of `workers/main.py`. Keep provider factories injected. Run current worker tests before continuing.

- [ ] **Step 3: Write failing reanalysis tests**

Assert current transcript text is loaded in timestamp order, chunks and only entities whose `conversation_id` matches the target are replaced transactionally, embeddings and summary/title are refreshed, duplicate queue messages converge, cross-conversation consolidated entities remain, and mocked Rules/integrations are never called.

- [ ] **Step 4: Implement queue consumer**

Consume `queue:reanalysis` with bounded retry/dead-letter behavior. Acquire Redis lock `reanalysis:{conversation_id}` with a five-minute TTL and periodic renewal. If acquisition fails, requeue with bounded backoff and do not analyze concurrently. On completion, check whether a newer `requested_at` arrived and repeat once rather than publishing stale results.

- [ ] **Step 5: Verify and commit**

```bash
cd backend
pytest tests/test_worker_pipeline.py tests/test_conversation_reanalysis.py -q
git add backend/app/services backend/app/workers/main.py backend/tests
git commit -m "feat: reanalyze corrected memories without actions"
```

### Task 6: Split Completed and Incomplete Audio Retention

**Files:**
- Modify: `backend/app/core/config.py`
- Modify: `backend/app/workers/retention.py`
- Modify: `backend/tests/test_retention.py`
- Modify: `docker-compose.yml`

**Interfaces:**
- Settings: `completed_audio_retention_hours=24`, `incomplete_audio_retention_days=7`.
- Completed audio is removed after 24 hours; pending, processing, and failed audio is removed after 7 days.
- Segment rows and all derived metadata remain until explicit conversation deletion.

- [ ] **Step 1: Write clock-controlled failing tests**

Characterize the current single 30-day cutoff first. Then create completed and non-completed records at 23h59m, 24h01m, 6d23h, and 7d01h. Assert completed audio is removed at 24h, non-completed audio remains until 7d, and every Segment/transcription/entity remains after its audio is cleared.

- [ ] **Step 2: Implement two retention passes**

Run every six hours and batch 100 IDs to avoid long transactions. Filter by transcription status for the two cutoffs. Delete external/local audio before clearing `audio_path` and `audio_size_bytes`; on storage deletion failure keep both references and retry next run. Do not delete Segment rows in retention.

- [ ] **Step 3: Configure defaults and verify**

```bash
cd backend
pytest tests/test_retention.py -q
git add backend/app/core/config.py backend/app/workers/retention.py backend/tests/test_retention.py docker-compose.yml
git commit -m "feat: enforce staged memory retention"
```

### Task 7: Complete Conversation Delete

**Files:**
- Modify: `backend/app/routers/conversations.py`
- Create: `backend/app/services/conversation_deleter.py`
- Create: `backend/tests/test_conversation_delete.py`
- Modify: `mobile/lib/services/api_service.dart`
- Test: `mobile/test/services/conversation_delete_test.dart`

**Interfaces:**
- `DELETE /api/conversations/{id}` returns 204.
- Foreign/missing conversation returns 404.
- Mobile `deleteConversation(String id)` expects 204.

- [ ] **Step 1: Write failing integration test**

Seed a conversation with audio files, Segment, transcription, audit edit, Chunk, entity, embedding, and relationships, plus a consolidated entity outside the target Conversation. Delete as owner and assert files and all target-dependent rows are gone while the external entity remains. Assert a storage failure returns 503 and preserves the database record for retry. Assert another API key gets 404 and deletes nothing.

- [ ] **Step 2: Implement owner-scoped delete**

Select by both conversation ID and authenticated user ID. In the service, remove referenced audio files first, treating already-missing files as success; if any other storage deletion fails, preserve the database rows and return 503. Then delete the Conversation and let PostgreSQL cascade. Do not issue ad hoc child deletes in the router.

- [ ] **Step 3: Add typed mobile API call and tests**

Assert success only on 204 and surface 404/500 via `ApiException`.

- [ ] **Step 4: Verify and commit**

```bash
cd backend && pytest tests/test_conversation_delete.py -q
cd ../mobile && flutter test test/services/conversation_delete_test.dart
git add backend mobile
git commit -m "feat: delete complete conversations"
```

### Task 8: Mobile Correction and Deletion Flow

**Files:**
- Modify: `mobile/lib/models/segment.dart`
- Modify: `mobile/lib/services/api_service.dart`
- Create: `mobile/lib/screens/transcript_detail_screen.dart`
- Create: `mobile/test/screens/transcript_detail_screen_test.dart`

**Interfaces:**
- Detail screen edits transcript text and speaker label together or separately.
- Save displays queued reanalysis state and updates local displayed value from server response.
- Delete conversation is destructive, confirmed, and only disappears locally after 204.

- [ ] **Step 1: Write failing widget tests**

Cover unchanged save disabled, text validation, speaker change, 202 queued state, queue-failed warning, API retry, delete cancel, delete success, and delete failure retaining the memory.

- [ ] **Step 2: Implement API method and detail flow**

Send the required full current text and normalized speaker enum even when only one changed. Disable duplicate submits while pending. On 202 update the model and show `Reprocessing memory`; on `queue_failed`, preserve the correction and show a retryable warning rather than rolling text back.

- [ ] **Step 3: Verify and commit**

```bash
cd mobile
flutter test test/screens/transcript_detail_screen_test.dart
flutter analyze
git add mobile/lib mobile/test/screens/transcript_detail_screen_test.dart
git commit -m "feat: edit and delete stored memories"
```

### Task 9: Memory Controls Acceptance Gate

**Files:**
- Modify only for focused defects.

- [ ] Apply migration to a copy of realistic data; downgrade and re-upgrade.
- [ ] Run `cd backend && pytest -q`.
- [ ] Run `cd mobile && flutter test && flutter analyze`.
- [ ] Correct text and speaker; confirm audit row and refreshed search/query output.
- [ ] Confirm correction invokes zero mocked/real integrations and Rules.
- [ ] Run retention at boundary timestamps and verify completed audio at 24h, non-completed audio at 7d, and metadata preservation.
- [ ] Delete a populated conversation and inspect every dependent table.
- [ ] Load and delete complete Ask history.
- [ ] Log out while connected and verify API key, wearable identity, active BLE work, and cached state are cleared.
- [ ] Do not start the mobile-experience plan until this gate passes.
