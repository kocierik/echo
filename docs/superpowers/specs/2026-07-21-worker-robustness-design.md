# Worker Robustness Design

**Date**: 2026-07-21
**Status**: Approved

## Overview

Make the background worker resilient to transient failures (OpenAI timeouts, network issues) with retry logic, graceful shutdown, and dead letter queue for unrecoverable failures.

## Retry with Exponential Backoff

- All OpenAI calls (STT, LLM analysis, embeddings) wrapped with retry utility
- 3 attempts, backoff: 1s → 4s → 16s (base=1, multiplier=4)
- Per-call timeout: 60 seconds (`asyncio.timeout`)
- After 3 failures → segment pushed to dead letter queue on Redis

## Dead Letter Queue

- Redis key: `queue:dead-letter`
- Each entry is a JSON object:
  ```json
  {
    "segment_id": "uuid",
    "step": "stt|analysis",
    "error": "error message",
    "attempts": 3,
    "failed_at": "ISO 8601 timestamp"
  }
  ```
- Segments in dead letter are not retried automatically

## Graceful Shutdown

- Signal handler registered for SIGTERM and SIGINT
- Sets an `asyncio.Event` flag (`shutdown_event`)
- Worker loops check `shutdown_event.is_set()` before popping new items
- After signal received, waits up to 30 seconds for in-progress tasks to complete
- If timeout expires, in-progress segments are pushed to dead letter queue with error "shutdown_timeout"
- Process exits with code 0

## Admin Endpoints

### GET /api/admin/dead-letter

Returns list of failed segments from the dead letter queue.

**Auth**: Same X-API-Key auth as other endpoints.

**Response**:
```json
{
  "items": [
    {
      "segment_id": "uuid",
      "step": "stt",
      "error": "Timeout after 60s",
      "attempts": 3,
      "failed_at": "2026-07-21T10:30:00Z"
    }
  ],
  "count": 1
}
```

### POST /api/admin/dead-letter/retry

Re-queues all dead letter items back to their appropriate queue (queue:stt or queue:analysis).

**Auth**: Same X-API-Key auth.

**Response**:
```json
{
  "requeued": 3
}
```

## File Structure

- `app/workers/retry.py` — retry decorator/utility with backoff and timeout
- `app/workers/main.py` — modified with signal handling, shutdown logic, retry usage
- `app/routers/admin.py` — dead letter admin endpoints

## Design Decisions

- Retry is per-call, not per-segment. If STT succeeds but analysis fails, the segment goes to analysis dead letter (not re-transcribed).
- Backoff is exponential to avoid hammering OpenAI during outages.
- Dead letter uses Redis (not Postgres) to keep it lightweight and avoid DB writes during failure scenarios.
- 30s shutdown timeout matches Docker's default SIGTERM grace period.
