"""Photos worker: vision answers for uploaded photos, and requests the wearable never answered.

`PUT /photos/{id}/image` pushes the photo id onto `queue:photos`; each one is analysed
(app/services/photos.py) with retries, each attempt in its own DB session. A photo the
model keeps failing on is reported in the chat. Requests still waiting for the wearable
after PHOTO_REQUEST_TIMEOUT_S fail, and the user is told.
"""

import asyncio
import logging
import time
import uuid

from app.core.database import async_session
from app.services.embedding_openai import get_embedding_service
from app.services.llm_openai import get_llm_analysis_service, get_llm_vision_service
from app.services.photos import (
    PHOTO_QUEUE,
    analyse_photo,
    expire_photo_requests,
    fail_analysis,
)
from app.workers.retry import RetryExhaustedError, retry_with_backoff

logger = logging.getLogger(__name__)

EXPIRE_EVERY_S = 10
POP_TIMEOUT_S = 2


async def _analyse_once(photo_id: uuid.UUID, session_factory) -> bool:
    async with session_factory() as db:
        return await analyse_photo(
            db,
            photo_id,
            get_llm_vision_service(),
            get_embedding_service(),
            analysis_llm=get_llm_analysis_service(),
        )


async def handle_photo(raw, session_factory=async_session) -> None:
    """Analyse one queued photo. Never raises (except cancellation)."""
    try:
        photo_id = uuid.UUID(raw.decode() if isinstance(raw, bytes) else str(raw))
    except (UnicodeDecodeError, ValueError):
        logger.warning(f"[Photos] Dropping invalid queue item {raw!r}")
        return
    try:
        await retry_with_backoff(
            _analyse_once,
            photo_id,
            session_factory,
            operation_name=f"Photo analysis {photo_id}",
        )
        logger.info(f"[Photos] Analysed photo {photo_id}")
    except asyncio.CancelledError:
        raise
    except RetryExhaustedError as exc:
        logger.error(f"[Photos] Analysis of {photo_id} failed: {exc.last_error}")
        await _report_analysis_failure(photo_id, session_factory)
    except Exception:
        logger.exception(f"[Photos] Analysis of {photo_id} failed")
        await _report_analysis_failure(photo_id, session_factory)


async def _report_analysis_failure(photo_id: uuid.UUID, session_factory) -> None:
    try:
        async with session_factory() as db:
            await fail_analysis(db, photo_id)
    except Exception:
        logger.exception(f"[Photos] Could not report the failure of {photo_id}")


async def _expire(session_factory) -> None:
    try:
        async with session_factory() as db:
            expired = await expire_photo_requests(db)
        if expired:
            logger.info(f"[Photos] {expired} photo request(s) timed out")
    except Exception:
        logger.exception("[Photos] Expiring photo requests failed")


async def process_photos(
    redis_client, shutdown_event: asyncio.Event, session_factory=async_session
) -> None:
    """Consume `queue:photos` until shutdown, expiring stale requests on the way."""
    last_expire = 0.0
    while not shutdown_event.is_set():
        if time.monotonic() - last_expire >= EXPIRE_EVERY_S:
            last_expire = time.monotonic()
            await _expire(session_factory)
        try:
            result = await redis_client.brpop(PHOTO_QUEUE, timeout=POP_TIMEOUT_S)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[Photos] Queue poll failed")
            await asyncio.sleep(POP_TIMEOUT_S)
            continue
        if result is not None:
            await handle_photo(result[1], session_factory)
