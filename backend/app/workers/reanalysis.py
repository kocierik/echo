"""Reanalysis worker: corrected conversations get their memory rebuilt.

`queue:reanalysis` holds `{conversation_id, requested_at, attempts}`. One worker at a time
rebuilds a conversation, under a Redis lock renewed while it runs; corrections that arrive
meanwhile leave a `reanalysis:latest:<id>` marker and are folded into the same run (up to
MAX_REANALYSES_PER_LOCK, then requeued). Payloads that cannot be read, or whose lock never
frees up, go to the dead letter queue.
"""

import asyncio
import json
import logging
import uuid
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime

import redis.asyncio as redis

from app.core.database import async_session
from app.services.conversation_reanalysis import reanalyse_conversation
from app.services.embedding_openai import get_embedding_service
from app.services.llm_openai import get_llm_analysis_service
from app.workers.dead_letter import push_reanalysis_to_dead_letter
from app.workers.queue import done, take

logger = logging.getLogger(__name__)

REANALYSIS_QUEUE = "queue:reanalysis"
REANALYSIS_LOCK_TTL_S = 300
REANALYSIS_LOCK_RENEWAL_S = 120
REANALYSIS_LOCK_BACKOFF_S = (2, 5, 10, 30)
MAX_REANALYSES_PER_LOCK = 3

_RENEW_LOCK_SCRIPT = """
if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('expire', KEYS[1], ARGV[2])
end
return 0
"""

_RELEASE_LOCK_SCRIPT = """
if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('del', KEYS[1])
end
return 0
"""

_DELETE_LATEST_IF_UNCHANGED_SCRIPT = """
-- Delete only the exact latest marker observed by this worker.
if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('del', KEYS[1])
end
return 0
"""


@dataclass(frozen=True)
class ReanalysisPayload:
    conversation_id: uuid.UUID
    requested_at: datetime
    attempts: int = 0

    def to_json(self) -> str:
        return json.dumps(
            {
                "conversation_id": str(self.conversation_id),
                "requested_at": self.requested_at.isoformat(),
                "attempts": self.attempts,
            }
        )


def _parse_aware_datetime(value: object) -> datetime:
    if not isinstance(value, str):
        raise ValueError("requested_at must be an ISO timestamp string")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("requested_at must include a timezone offset")
    return parsed


def _parse_reanalysis_payload(raw_payload: str | bytes) -> ReanalysisPayload:
    decoded = raw_payload.decode() if isinstance(raw_payload, bytes) else raw_payload
    data = json.loads(decoded)
    if not isinstance(data, dict):
        raise ValueError("reanalysis payload must be a JSON object")

    conversation_id = uuid.UUID(str(data.get("conversation_id", "")))
    requested_at = _parse_aware_datetime(data.get("requested_at"))
    attempts = data.get("attempts", 0)
    if isinstance(attempts, bool) or not isinstance(attempts, int) or attempts < 0:
        raise ValueError("attempts must be a non-negative integer")
    return ReanalysisPayload(conversation_id, requested_at, attempts)


def _decode_redis_token(value: object) -> str | None:
    if isinstance(value, bytes):
        try:
            return value.decode()
        except UnicodeDecodeError:
            return None
    return value if isinstance(value, str) else None


async def _renew_reanalysis_lock(
    redis_client: redis.Redis,
    lock_key: str,
    lock_token: str,
    lock_lost: asyncio.Event,
):
    try:
        while True:
            await asyncio.sleep(REANALYSIS_LOCK_RENEWAL_S)
            renewed = await redis_client.eval(
                _RENEW_LOCK_SCRIPT,
                1,
                lock_key,
                lock_token,
                REANALYSIS_LOCK_TTL_S,
            )
            if not renewed:
                lock_lost.set()
                logger.warning(f"[Reanalysis] Lost distributed lock {lock_key}")
                return
    except asyncio.CancelledError:
        raise
    except Exception:
        lock_lost.set()
        logger.exception(f"[Reanalysis] Failed to renew distributed lock {lock_key}")


async def _owns_reanalysis_lock(
    redis_client: redis.Redis,
    lock_key: str,
    lock_token: str,
    lock_lost: asyncio.Event,
) -> bool:
    if lock_lost.is_set():
        return False
    try:
        observed_token = await redis_client.get(lock_key)
    except asyncio.CancelledError:
        raise
    except Exception:
        lock_lost.set()
        logger.exception(f"[Reanalysis] Failed to verify distributed lock {lock_key}")
        return False

    owns_lock = _decode_redis_token(observed_token) == lock_token
    if not owns_lock:
        lock_lost.set()
    return owns_lock


async def _requeue_after_reanalysis_lock_loss(
    redis_client: redis.Redis,
    payload: ReanalysisPayload,
    requested_at: datetime,
) -> None:
    max_retry_attempt = max(0, len(REANALYSIS_LOCK_BACKOFF_S) - 1)
    retry_payload = ReanalysisPayload(
        payload.conversation_id,
        requested_at,
        min(payload.attempts + 1, max_retry_attempt),
    )
    await redis_client.lpush(REANALYSIS_QUEUE, retry_payload.to_json())
    logger.warning(
        f"[Reanalysis] Requeued conversation {payload.conversation_id} after lock loss"
    )


async def _process_reanalysis_payload(
    redis_client: redis.Redis,
    raw_payload: str | bytes,
    llm_service,
    embedding_service,
):
    decoded_payload = (
        raw_payload.decode(errors="replace")
        if isinstance(raw_payload, bytes)
        else raw_payload
    )
    try:
        payload = _parse_reanalysis_payload(raw_payload)
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        await push_reanalysis_to_dead_letter(redis_client, decoded_payload, str(exc))
        return

    current_payload = payload.to_json()
    lock_key = f"reanalysis:lock:{payload.conversation_id}"
    lock_token = uuid.uuid4().hex
    lock_acquired = False
    lock_lost = asyncio.Event()
    renewal_task: asyncio.Task | None = None

    try:
        lock_acquired = bool(
            await redis_client.set(
                lock_key,
                lock_token,
                nx=True,
                ex=REANALYSIS_LOCK_TTL_S,
            )
        )
        if not lock_acquired:
            if payload.attempts >= len(REANALYSIS_LOCK_BACKOFF_S):
                await push_reanalysis_to_dead_letter(
                    redis_client,
                    current_payload,
                    "distributed lock unavailable",
                    attempts=payload.attempts,
                    conversation_id=payload.conversation_id,
                )
                return

            await asyncio.sleep(REANALYSIS_LOCK_BACKOFF_S[payload.attempts])
            retry_payload = ReanalysisPayload(
                payload.conversation_id,
                payload.requested_at,
                payload.attempts + 1,
            )
            await redis_client.lpush(REANALYSIS_QUEUE, retry_payload.to_json())
            return

        renewal_task = asyncio.create_task(
            _renew_reanalysis_lock(
                redis_client,
                lock_key,
                lock_token,
                lock_lost,
            ),
            name=f"reanalysis_lock_{payload.conversation_id}",
        )
        processed_at = payload.requested_at
        latest_key = f"reanalysis:latest:{payload.conversation_id}"

        for run_index in range(MAX_REANALYSES_PER_LOCK):
            if not await _owns_reanalysis_lock(
                redis_client,
                lock_key,
                lock_token,
                lock_lost,
            ):
                await _requeue_after_reanalysis_lock_loss(
                    redis_client,
                    payload,
                    processed_at,
                )
                return

            async with async_session() as db:
                result = await reanalyse_conversation(
                    db,
                    payload.conversation_id,
                    llm_service,
                    embedding_service,
                )
            if not await _owns_reanalysis_lock(
                redis_client,
                lock_key,
                lock_token,
                lock_lost,
            ):
                await _requeue_after_reanalysis_lock_loss(
                    redis_client,
                    payload,
                    processed_at,
                )
                return
            if not result.found:
                logger.warning(
                    f"[Reanalysis] Conversation {payload.conversation_id} not found"
                )
                return

            latest_raw = await redis_client.get(latest_key)
            if latest_raw is None:
                return
            if isinstance(latest_raw, bytes):
                latest_raw = latest_raw.decode()
            try:
                latest_at = _parse_aware_datetime(latest_raw)
            except (TypeError, ValueError):
                logger.warning(
                    f"[Reanalysis] Ignoring invalid latest marker for "
                    f"{payload.conversation_id}"
                )
                return

            if latest_at <= processed_at:
                await redis_client.eval(
                    _DELETE_LATEST_IF_UNCHANGED_SCRIPT,
                    1,
                    latest_key,
                    latest_raw,
                )
                return
            if run_index == MAX_REANALYSES_PER_LOCK - 1:
                latest_payload = ReanalysisPayload(
                    payload.conversation_id,
                    latest_at,
                )
                await redis_client.lpush(REANALYSIS_QUEUE, latest_payload.to_json())
                return
            processed_at = latest_at

    except asyncio.CancelledError:
        await redis_client.lpush(REANALYSIS_QUEUE, current_payload)
        raise
    except Exception as exc:
        logger.exception(
            f"[Reanalysis] Failed conversation {payload.conversation_id}: {exc}"
        )
        await push_reanalysis_to_dead_letter(
            redis_client,
            current_payload,
            str(exc),
            attempts=getattr(exc, "attempts", payload.attempts),
            conversation_id=payload.conversation_id,
        )
    finally:
        if renewal_task is not None:
            renewal_task.cancel()
            with suppress(asyncio.CancelledError):
                await renewal_task
        if lock_acquired:
            try:
                await redis_client.eval(
                    _RELEASE_LOCK_SCRIPT,
                    1,
                    lock_key,
                    lock_token,
                )
            except Exception:
                logger.exception(f"[Reanalysis] Failed to release lock {lock_key}")


async def process_reanalysis(redis_client: redis.Redis, shutdown_event: asyncio.Event):
    """Consume corrected conversations and rebuild their derived memory."""
    llm_service = get_llm_analysis_service()
    embedding_service = get_embedding_service()

    while not shutdown_event.is_set():
        payload = await take(redis_client, REANALYSIS_QUEUE)
        if payload is None:
            continue
        try:
            await _process_reanalysis_payload(
                redis_client,
                payload,
                llm_service,
                embedding_service,
            )
        finally:
            await done(redis_client, REANALYSIS_QUEUE, payload)
