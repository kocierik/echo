# Speaker Detection + Feedback Loop — Design Spec

## Goal

Add two capabilities to Echo:
1. **Speaker detection** — Distinguish "you" from "others" in transcriptions using audio energy proximity
2. **Feedback loop** — Allow the user to correct entities and rate RAG responses, with the system learning from corrections

## Architecture

```
Device (firmware)                    Backend
┌────────────────┐                  ┌──────────────────────────┐
│ VAD + ADPCM    │  X-Audio-Energy  │ POST /api/segments       │
│ + RMS energy   │ ───────────────▶ │   → save audio_energy    │
│   calculation  │                  │   → speaker_detector.py  │
└────────────────┘                  │      classifies self/other│
                                    └──────────────────────────┘
                                               │
                                    ┌──────────▼──────────────┐
                                    │ Transcription prefixed:  │
                                    │ [Tu] Ciao Marco          │
                                    │ [Altri] Sì, dimmi        │
                                    └──────────────────────────┘

Feedback:
┌─────────────┐    PATCH /api/entities/{id}     ┌────────────────┐
│   Web UI    │ ─────────────────────────────▶  │ Entity CRUD    │
│  ✏️ 🗑️ 👍👎  │    POST /api/query/feedback     │ + re-embed     │
└─────────────┘ ─────────────────────────────▶  │ Feedback store │
                                                └────────────────┘
```

---

## Part 1: Speaker Detection

### Firmware Changes

The firmware already calculates RMS energy for VAD. Add:
- Compute average RMS over the entire segment
- Send as HTTP header `X-Audio-Energy: <uint16_value>` with each POST

### Backend — Ingest

- New field `audio_energy: int | None` on `Segment` model
- Parsed from `X-Audio-Energy` header (optional, backward compatible)

### Backend — Speaker Classification

New service `app/services/speaker_detector.py`:

```python
class SpeakerDetector:
    """Classifies segments as 'self' or 'other' based on audio energy."""
    
    CALIBRATION_SEGMENTS = 20  # segments needed before classification starts
    
    async def classify(self, segment, db) -> str:
        # Returns "self" | "other" | "unknown"
        # Logic:
        # 1. If < CALIBRATION_SEGMENTS exist, return "unknown"
        # 2. Compute energy threshold = percentile 70 of user's recent segments
        # 3. If segment.audio_energy >= threshold → "self"
        # 4. Else → "other"
```

- Threshold stored in Redis as `speaker_threshold:{user_id}` (cached, recalculated every 50 segments)
- Configurable via `SPEAKER_ENERGY_THRESHOLD` env var (manual override)

### Backend — Transcription Prefixing

In the worker, after STT completes:
- Classify the segment's speaker
- Save `speaker` field on segment
- Prefix transcription text with `[Tu]` or `[Altri]` before saving

This prefix flows naturally into:
- Entity extraction (LLM sees who said what)
- Chunk embeddings (semantic search can match "what did I say" vs "what did others say")
- RAG context (LLM knows speaker attribution)

### Model Changes

```sql
ALTER TABLE segments ADD COLUMN audio_energy INTEGER;
ALTER TABLE segments ADD COLUMN speaker TEXT DEFAULT 'unknown';  -- self | other | unknown
```

---

## Part 2: Entity Feedback (CRUD)

### API Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `PATCH` | `/api/entities/{id}` | Update name, content, type, metadata |
| `DELETE` | `/api/entities/{id}` | Delete an incorrect entity |
| `POST` | `/api/entities/{id}/merge` | Merge entity into another (body: `{"target_id": "..."}`) |

### PATCH Behavior

- Accepts partial updates (only changed fields)
- If `name` changes → queue re-embedding via Redis (`queue:re-embed`)
- Worker picks up re-embed jobs and updates the entity's vector
- `updated_at` refreshed

### DELETE Behavior

- Soft consideration: we hard-delete since entities are extracted, not user-created
- Returns 204 No Content

### Merge Behavior

- `POST /api/entities/{source_id}/merge` with body `{"target_id": "uuid"}`
- Merges source content/metadata into target (same logic as dedup merge)
- Deletes source entity
- Returns updated target entity

### Web UI Integration

- Entity list view: each row gets ✏️ (edit) and 🗑️ (delete) icons
- Edit: inline form (name, type dropdown, content textarea)
- Conversation detail: entities section shows edit/delete per entity

---

## Part 3: RAG Response Feedback

### API Endpoint

`POST /api/query/feedback`

```json
{
  "session_id": "uuid-string",
  "message_index": 1,
  "rating": "positive",
  "comment": null
}
```

- `message_index`: which assistant message in the session (0-indexed)
- `rating`: `"positive"` or `"negative"`
- `comment`: optional free text

### Storage

New table `query_feedback`:

```sql
CREATE TABLE query_feedback (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    session_id UUID NOT NULL,
    message_index INTEGER NOT NULL,
    rating TEXT NOT NULL,  -- 'positive' | 'negative'
    comment TEXT,
    source_chunk_ids JSONB NOT NULL DEFAULT '[]',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_feedback_user ON query_feedback (user_id, created_at DESC);
CREATE INDEX idx_feedback_chunks ON query_feedback USING gin (source_chunk_ids);
```

### Feedback Effect on RAG

In `query.py`, after retrieving chunks by similarity:
- Look up feedback for those chunk IDs
- Apply multiplier:
  - Chunk with net positive feedback: similarity × 1.05
  - Chunk with net negative feedback: similarity × 0.9
  - Chunk with 3+ net negative: excluded from results (flagged for review)
- This is a simple post-retrieval re-ranking step

### Web UI Integration

- After each assistant message in chat: 👍 / 👎 buttons
- 👎 click → optional textarea "Cosa c'era di sbagliato?"
- Visual confirmation after submission (button turns solid/colored)
- Feedback persisted even if session expires from Redis

---

## Configuration

New env vars:

| Variable | Default | Description |
|----------|---------|-------------|
| `SPEAKER_ENERGY_THRESHOLD` | (auto) | Manual override for speaker energy threshold |
| `SPEAKER_CALIBRATION_SEGMENTS` | `20` | Segments needed before auto-calibration |
| `FEEDBACK_POSITIVE_BOOST` | `1.05` | Similarity multiplier for positive chunks |
| `FEEDBACK_NEGATIVE_PENALTY` | `0.9` | Similarity multiplier for negative chunks |
| `FEEDBACK_EXCLUDE_THRESHOLD` | `3` | Net negative count to exclude a chunk |

---

## Migration Plan

1. Alembic migration: add `audio_energy`, `speaker` columns to segments
2. Alembic migration: create `query_feedback` table
3. Firmware update: add `X-Audio-Energy` header
4. Deploy backend with new services (backward compatible — energy is optional)
5. Update Web UI with feedback buttons and entity edit/delete

---

## Out of Scope (for later)

- Voice fingerprinting / speaker embeddings (Approccio 2)
- ML-based feedback ranking (start simple with static multipliers)
- Feedback on entity extraction quality (complex UX)
- Merge UI in frontend (API-only for now)
