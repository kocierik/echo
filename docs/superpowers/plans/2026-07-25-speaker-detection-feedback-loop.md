# Speaker Detection + Feedback Loop — Implementation Plan

> **Stato (13/10/2026): implementato** — commit db997cc. Le checkbox qui sotto non sono state aggiornate durante l'implementazione; lo stato attuale è in [PROJECT-STATUS.md](../../PROJECT-STATUS.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add speaker detection (self vs others) via audio energy and a feedback loop (entity CRUD + RAG response rating) to Echo.

**Architecture:** Firmware sends energy header → backend classifies speaker → transcriptions get prefixed. Separate: entity CRUD endpoints + feedback table with re-ranking in RAG query.

**Tech Stack:** Python/FastAPI, SQLAlchemy, Alembic, Redis, PostgreSQL, HTML/JS (static UI)

## Global Constraints

- Python 3.11+, FastAPI 0.115, SQLAlchemy 2.0 async
- All new endpoints require `X-API-Key` auth via `get_current_user_id`
- Alembic migration for every schema change
- Ruff lint must pass
- Unit tests for pure logic, integration tests for endpoints

---

### Task 1: Database Migration — Speaker & Feedback Schema

**Files:**
- Create: `backend/alembic/versions/003_add_speaker_and_feedback.py`
- Modify: `backend/app/models/segment.py`
- Create: `backend/app/models/query_feedback.py`

**Interfaces:**
- Produces: `Segment.audio_energy`, `Segment.speaker` columns; `QueryFeedback` model

- [ ] **Step 1: Create the migration file**

```python
# backend/alembic/versions/003_add_speaker_and_feedback.py
"""Add speaker detection and query feedback tables.

Revision ID: 003
Revises: 002
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "003"
down_revision: Union[str, None] = "002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Speaker detection columns
    op.add_column("segments", sa.Column("audio_energy", sa.Integer(), nullable=True))
    op.add_column("segments", sa.Column("speaker", sa.String(10), nullable=True, server_default="unknown"))

    # Query feedback table
    op.create_table(
        "query_feedback",
        sa.Column("id", sa.dialects.postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("uuid_generate_v4()")),
        sa.Column("user_id", sa.dialects.postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("session_id", sa.dialects.postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("message_index", sa.Integer(), nullable=False),
        sa.Column("rating", sa.String(10), nullable=False),
        sa.Column("comment", sa.Text(), nullable=True),
        sa.Column("source_chunk_ids", sa.dialects.postgresql.JSONB(), nullable=False, server_default="[]"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )
    op.create_index("idx_feedback_user", "query_feedback", ["user_id", "created_at"])
    op.create_index("idx_feedback_chunks", "query_feedback", ["source_chunk_ids"], postgresql_using="gin")


def downgrade() -> None:
    op.drop_table("query_feedback")
    op.drop_column("segments", "speaker")
    op.drop_column("segments", "audio_energy")
```

- [ ] **Step 2: Update Segment model**

Add to `backend/app/models/segment.py`:
```python
audio_energy: Mapped[int | None] = mapped_column(Integer, nullable=True)
speaker: Mapped[str | None] = mapped_column(
    String(10), nullable=True, default="unknown",
    comment="self | other | unknown"
)
```

- [ ] **Step 3: Create QueryFeedback model**

```python
# backend/app/models/query_feedback.py
import uuid
from datetime import datetime
from sqlalchemy import DateTime, Integer, String, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column
from app.models.base import Base, UUIDPrimaryKey


class QueryFeedback(UUIDPrimaryKey, Base):
    __tablename__ = "query_feedback"

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    session_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    message_index: Mapped[int] = mapped_column(Integer, nullable=False)
    rating: Mapped[str] = mapped_column(String(10), nullable=False)  # positive | negative
    comment: Mapped[str | None] = mapped_column(Text, nullable=True)
    source_chunk_ids: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc)
    )
```

- [ ] **Step 4: Verify migration file lint passes**

Run: `cd backend && python -m ruff check alembic/ app/models/`
Expected: All checks passed

- [ ] **Step 5: Commit**

```bash
git add backend/alembic/versions/003_add_speaker_and_feedback.py backend/app/models/segment.py backend/app/models/query_feedback.py
git commit -m "feat(schema): add speaker detection columns and query_feedback table"
```

---

### Task 2: Speaker Detection Service

**Files:**
- Create: `backend/app/services/speaker_detector.py`
- Create: `backend/tests/test_speaker_detector.py`

**Interfaces:**
- Consumes: `Segment.audio_energy`, `Segment.user_id`
- Produces: `classify(segment, db) -> "self" | "other" | "unknown"`

- [ ] **Step 1: Write the test**

```python
# backend/tests/test_speaker_detector.py
"""Unit tests for speaker detection logic."""

from app.services.speaker_detector import compute_threshold, classify_energy


class TestComputeThreshold:
    def test_empty_list(self):
        assert compute_threshold([]) is None

    def test_single_value(self):
        assert compute_threshold([100]) == 100

    def test_percentile_70(self):
        # 10 values: threshold should be around the 70th percentile
        values = list(range(100, 200, 10))  # [100,110,120,...,190]
        threshold = compute_threshold(values)
        assert 150 <= threshold <= 180

    def test_typical_distribution(self):
        # Simulate: user speaks loudly (high energy), others are quieter
        energies = [3000, 3200, 2800, 3100, 2900,  # self (loud)
                    800, 900, 750, 850, 700]         # other (quiet)
        threshold = compute_threshold(energies)
        # Should be high enough to separate the two clusters
        assert threshold > 1500


class TestClassifyEnergy:
    def test_above_threshold_is_self(self):
        assert classify_energy(3000, 2000) == "self"

    def test_below_threshold_is_other(self):
        assert classify_energy(800, 2000) == "other"

    def test_equal_to_threshold_is_self(self):
        assert classify_energy(2000, 2000) == "self"

    def test_no_threshold_is_unknown(self):
        assert classify_energy(3000, None) == "unknown"

    def test_no_energy_is_unknown(self):
        assert classify_energy(None, 2000) == "unknown"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m pytest tests/test_speaker_detector.py -v --noconftest`
Expected: FAIL (module not found)

- [ ] **Step 3: Implement speaker_detector.py**

```python
# backend/app/services/speaker_detector.py
"""Speaker detection based on audio energy proximity.

The wearable device is on the user's body, so the user's voice has
higher energy (closer to mic) than other speakers (further away).

Strategy:
- Collect energy values from recent segments
- Compute percentile 70 as threshold (user's voice dominates)
- Classify: energy >= threshold → "self", else → "other"
"""

import logging
import uuid
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)

CALIBRATION_SEGMENTS = 20
CACHE_RECALCULATE_EVERY = 50


def compute_threshold(energies: list[int]) -> int | None:
    """Compute the speaker energy threshold from historical data.

    Uses percentile 70: the user's voice appears most often and loudest,
    so the 70th percentile separates "self" from "other".
    """
    if not energies:
        return None

    sorted_e = sorted(energies)
    idx = int(len(sorted_e) * 0.7)
    idx = min(idx, len(sorted_e) - 1)
    return sorted_e[idx]


def classify_energy(energy: int | None, threshold: int | None) -> str:
    """Classify a segment's speaker based on energy vs threshold."""
    if energy is None or threshold is None:
        return "unknown"
    return "self" if energy >= threshold else "other"


async def classify_segment(
    db: "AsyncSession",
    user_id: uuid.UUID,
    audio_energy: int | None,
    redis_client=None,
) -> str:
    """Classify a segment's speaker with auto-calibrating threshold.

    Args:
        db: Database session.
        user_id: User owning the segment.
        audio_energy: RMS energy value from the device.
        redis_client: Optional Redis for caching threshold.

    Returns:
        "self" | "other" | "unknown"
    """
    if audio_energy is None:
        return "unknown"

    from sqlalchemy import select
    from app.models.segment import Segment
    from app.core.config import settings

    # Check for manual override
    manual_threshold = getattr(settings, "speaker_energy_threshold", None)
    if manual_threshold and manual_threshold > 0:
        return classify_energy(audio_energy, manual_threshold)

    # Try cached threshold from Redis
    cache_key = f"speaker_threshold:{user_id}"
    if redis_client:
        cached = await redis_client.get(cache_key)
        if cached:
            return classify_energy(audio_energy, int(cached))

    # Calculate from recent segments
    recent_query = (
        select(Segment.audio_energy)
        .where(Segment.user_id == user_id)
        .where(Segment.audio_energy.isnot(None))
        .order_by(Segment.recorded_at.desc())
        .limit(100)
    )
    result = await db.execute(recent_query)
    energies = [row[0] for row in result.all()]

    if len(energies) < CALIBRATION_SEGMENTS:
        return "unknown"

    threshold = compute_threshold(energies)
    if threshold is None:
        return "unknown"

    # Cache in Redis for 1 hour
    if redis_client:
        await redis_client.set(cache_key, str(threshold), ex=3600)

    return classify_energy(audio_energy, threshold)
```

- [ ] **Step 4: Run tests**

Run: `cd backend && python -m pytest tests/test_speaker_detector.py -v --noconftest`
Expected: PASS (all 9 tests)

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/speaker_detector.py backend/tests/test_speaker_detector.py
git commit -m "feat: speaker detection service with energy-based classification"
```

---

### Task 3: Integrate Speaker Detection in Worker Pipeline

**Files:**
- Modify: `backend/app/routers/segments.py` (accept `X-Audio-Energy` header)
- Modify: `backend/app/workers/main.py` (classify + prefix transcription)

**Interfaces:**
- Consumes: `speaker_detector.classify_segment()`, `Segment.audio_energy`
- Produces: Transcription text prefixed with `[Tu]` or `[Altri]`, `Segment.speaker` field set

- [ ] **Step 1: Update segments router to accept X-Audio-Energy**

Add to `ingest_segment()` parameters:
```python
audio_energy: int | None = Header(None, alias="X-Audio-Energy"),
```

Save to segment:
```python
segment = Segment(
    ...
    audio_energy=audio_energy,
    ...
)
```

- [ ] **Step 2: Update worker to classify and prefix**

In `process_stt()`, after `cleaned_text = clean_transcription(...)`:
```python
# Classify speaker
from app.services.speaker_detector import classify_segment
speaker = await classify_segment(db, segment.user_id, segment.audio_energy, redis_client=None)
segment.speaker = speaker

# Prefix transcription with speaker tag
if speaker == "self":
    cleaned_text = f"[Tu] {cleaned_text}"
elif speaker == "other":
    cleaned_text = f"[Altri] {cleaned_text}"
```

- [ ] **Step 3: Run lint**

Run: `cd backend && python -m ruff check app/routers/segments.py app/workers/main.py`
Expected: All checks passed

- [ ] **Step 4: Commit**

```bash
git add backend/app/routers/segments.py backend/app/workers/main.py
git commit -m "feat: integrate speaker detection in ingest and STT pipeline"
```

---

### Task 4: Entity CRUD Endpoints

**Files:**
- Modify: `backend/app/routers/entities.py` (add PATCH, DELETE, merge)
- Create: `backend/tests/test_entity_crud.py`

**Interfaces:**
- Consumes: `Entity` model, `get_embedding_service()`
- Produces: `PATCH /api/entities/{id}`, `DELETE /api/entities/{id}`, `POST /api/entities/{id}/merge`

- [ ] **Step 1: Write integration tests**

```python
# backend/tests/test_entity_crud.py
"""Integration tests for entity CRUD endpoints."""
import uuid
import pytest
from httpx import AsyncClient
from sqlalchemy import text
from tests.conftest import TEST_USER_ID


@pytest.mark.asyncio
async def test_patch_entity(client, auth_headers, db_session):
    # Insert entity
    entity_id = uuid.uuid4()
    await db_session.execute(text(
        "INSERT INTO entities (id, user_id, entity_type, name, content, metadata) "
        "VALUES (:id, :uid, 'person', 'Marco', 'collega', '{}')"
    ), {"id": str(entity_id), "uid": str(TEST_USER_ID)})
    await db_session.commit()

    # Patch
    resp = await client.patch(
        f"/api/entities/{entity_id}",
        headers=auth_headers,
        json={"name": "Marco Rossi", "content": "collega di marketing"}
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Marco Rossi"


@pytest.mark.asyncio
async def test_delete_entity(client, auth_headers, db_session):
    entity_id = uuid.uuid4()
    await db_session.execute(text(
        "INSERT INTO entities (id, user_id, entity_type, name, metadata) "
        "VALUES (:id, :uid, 'note', 'Test', '{}')"
    ), {"id": str(entity_id), "uid": str(TEST_USER_ID)})
    await db_session.commit()

    resp = await client.delete(f"/api/entities/{entity_id}", headers=auth_headers)
    assert resp.status_code == 204


@pytest.mark.asyncio
async def test_delete_entity_not_found(client, auth_headers):
    fake_id = uuid.uuid4()
    resp = await client.delete(f"/api/entities/{fake_id}", headers=auth_headers)
    assert resp.status_code == 404
```

- [ ] **Step 2: Implement endpoints in entities.py**

Add to `backend/app/routers/entities.py`:

```python
class EntityUpdate(BaseModel):
    name: str | None = None
    content: str | None = None
    entity_type: str | None = None
    metadata_: dict | None = None


@router.patch("/{entity_id}", response_model=EntityOut)
async def update_entity(
    entity_id: uuid.UUID,
    update: EntityUpdate,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Update an entity's fields. Re-embeds if name changes."""
    ...


@router.delete("/{entity_id}", status_code=204)
async def delete_entity(
    entity_id: uuid.UUID,
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Delete an entity."""
    ...


@router.post("/{entity_id}/merge")
async def merge_entity(
    entity_id: uuid.UUID,
    body: dict,  # {"target_id": "uuid"}
    user_id: uuid.UUID = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Merge this entity into target. Deletes source, updates target."""
    ...
```

- [ ] **Step 3: Run lint and tests**

Run: `cd backend && python -m ruff check app/routers/entities.py tests/test_entity_crud.py`
Expected: All checks passed

- [ ] **Step 4: Commit**

```bash
git add backend/app/routers/entities.py backend/tests/test_entity_crud.py
git commit -m "feat: entity CRUD endpoints (PATCH, DELETE, merge)"
```

---

### Task 5: Query Feedback Endpoint + RAG Re-ranking

**Files:**
- Create: `backend/app/routers/feedback.py`
- Modify: `backend/app/routers/query.py` (save source_chunk_ids, apply feedback re-ranking)
- Modify: `backend/app/main.py` (register feedback router)
- Create: `backend/tests/test_feedback.py`

**Interfaces:**
- Consumes: `QueryFeedback` model, `QueryResponse.sources`
- Produces: `POST /api/query/feedback`, modified similarity scoring in query

- [ ] **Step 1: Create feedback router**

```python
# backend/app/routers/feedback.py
"""Query feedback API: rate RAG responses."""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.query_feedback import QueryFeedback

router = APIRouter(prefix="/query/feedback", tags=["feedback"])


class FeedbackRequest(BaseModel):
    session_id: str
    message_index: int
    rating: str  # "positive" | "negative"
    comment: str | None = None
    source_chunk_ids: list[str] = []


@router.post("", status_code=201)
async def submit_feedback(
    request: FeedbackRequest,
    user_id = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    ...
```

- [ ] **Step 2: Modify query.py to track source_chunk_ids in response metadata**

Add chunk IDs to the session history so the UI can send them back with feedback.

- [ ] **Step 3: Add re-ranking logic in query.py**

After retrieving chunks by similarity, apply feedback multipliers:
```python
async def apply_feedback_reranking(db, user_id, rows):
    # Fetch feedback for chunk IDs in results
    # Apply boost/penalty multipliers
    # Exclude chunks with 3+ net negative
    ...
```

- [ ] **Step 4: Register router in main.py**

```python
from app.routers import feedback
app.include_router(feedback.router, prefix=settings.api_prefix)
```

- [ ] **Step 5: Write tests**

```python
# backend/tests/test_feedback.py
@pytest.mark.asyncio
async def test_submit_positive_feedback(client, auth_headers):
    resp = await client.post("/api/query/feedback", headers=auth_headers, json={
        "session_id": str(uuid.uuid4()),
        "message_index": 0,
        "rating": "positive",
        "source_chunk_ids": []
    })
    assert resp.status_code == 201
```

- [ ] **Step 6: Run lint + tests**

Run: `cd backend && python -m ruff check app/ tests/ && python -m pytest tests/test_feedback.py -v`
Expected: All checks passed

- [ ] **Step 7: Commit**

```bash
git add backend/app/routers/feedback.py backend/app/routers/query.py backend/app/main.py backend/tests/test_feedback.py
git commit -m "feat: query feedback endpoint with RAG re-ranking"
```

---

### Task 6: Firmware — Add X-Audio-Energy Header

**Files:**
- Modify: `firmware/src/http_sender.h`

**Interfaces:**
- Consumes: RMS energy calculated in VAD
- Produces: `X-Audio-Energy: <uint16>` header in HTTP POST

- [ ] **Step 1: Add energy header to HTTP POST**

In `http_sender.h`, in the function that builds the HTTP request, add:
```cpp
// After existing headers
http.addHeader("X-Audio-Energy", String(avg_rms_energy));
```

Where `avg_rms_energy` is computed during the segment recording (average of per-frame RMS values already calculated by VAD).

- [ ] **Step 2: Verify firmware compiles**

Run: `cd firmware && pio run --environment xiao_esp32s3`
Expected: Build SUCCESS

- [ ] **Step 3: Commit**

```bash
git add firmware/src/http_sender.h
git commit -m "feat(firmware): send X-Audio-Energy header with audio segments"
```

---

### Task 7: Final Integration + Push

**Files:**
- Modify: `docs/ROADMAP.md` (mark completed items)
- Modify: `.github/workflows/ci.yml` (add new test files)

- [ ] **Step 1: Update CI to include new test files**

Add `tests/test_speaker_detector.py` to unit test list.

- [ ] **Step 2: Update roadmap**

Mark speaker diarization and feedback items as done in Fase 3.

- [ ] **Step 3: Full lint + test run**

Run: `cd backend && python -m ruff check app/ tests/ && python -m pytest tests/test_adpcm_decoder.py tests/test_temporal.py tests/test_chunking.py tests/test_circuit_breaker.py tests/test_transcription_enhancer.py tests/test_entity_consolidation.py tests/test_speaker_detector.py -v --noconftest`
Expected: All pass

- [ ] **Step 4: Push all commits**

```bash
GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519_personal -o IdentitiesOnly=yes" git push
```
