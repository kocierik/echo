"""Structured JSON logging configuration for Echo."""

import json
import logging
import sys
import uuid
from contextvars import ContextVar
from datetime import datetime, timezone

from app.core.config import settings

logger = logging.getLogger(__name__)

# Context variable for request/segment correlation
correlation_id: ContextVar[str] = ContextVar("correlation_id", default="")


class JSONFormatter(logging.Formatter):
    """Emit structured JSON log lines."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        # Add correlation ID if set
        corr_id = correlation_id.get()
        if corr_id:
            log_entry["correlation_id"] = corr_id

        # Add exception info if present
        if record.exc_info and record.exc_info[0] is not None:
            log_entry["exception"] = self.formatException(record.exc_info)

        # Add extra fields passed via logging
        for key in (
            "segment_id", "user_id", "duration_ms", "step", "run_id", "error_class", "agent_id",
        ):
            val = getattr(record, key, None)
            if val is not None:
                log_entry[key] = str(val)

        return json.dumps(log_entry, ensure_ascii=False)


def setup_logging(level: str = "INFO") -> None:
    """Configure structured JSON logging for all loggers."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JSONFormatter())

    # Root logger
    root = logging.getLogger()
    root.setLevel(getattr(logging, level.upper(), logging.INFO))
    root.handlers = [handler]

    # Quiet noisy libraries
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("sqlalchemy.engine").setLevel(logging.WARNING)


def new_correlation_id() -> str:
    """Generate and set a new correlation ID for the current context."""
    cid = str(uuid.uuid4())[:8]
    correlation_id.set(cid)
    return cid


# --- One correlation ID from the upload to the workers ----------------------------------
#
# The queues carry bare ids, and their format does not change: the request that uploads a
# segment or a photo keeps its correlation ID in Redis beside the object
# (corr:segment:{id}, corr:photo:{id}), and every worker that picks the id up restores it.
# A retry, a requeue or a replay from the dead letter queue finds the same key. Written
# only with run tracking on; a missing or expired key, or Redis failing, gives the worker
# a new ID and never stops the work.


def _correlation_key(kind: str, object_id) -> str:
    return f"corr:{kind}:{object_id}"


async def remember_correlation(redis, kind: str, object_id) -> None:
    """Keep the current correlation ID for the workers that will handle `object_id`.

    Call it before queueing the id. Never raises.
    """
    cid = correlation_id.get()
    if not settings.run_tracking_enabled or not cid:
        return
    try:
        await redis.set(
            _correlation_key(kind, object_id), cid, ex=settings.correlation_key_ttl_seconds
        )
    except Exception as exc:
        logger.warning(
            "Could not keep the correlation ID of a %s", kind,
            extra={"error_class": type(exc).__name__},
        )


async def restore_correlation_for(redis, kind: str, object_id) -> str:
    """Make the correlation ID kept for `object_id` the current one (a new one when there
    is none) and return it. Call it when a worker picks the id up. Never raises."""
    if settings.run_tracking_enabled:
        try:
            kept = await redis.get(_correlation_key(kind, object_id))
            if isinstance(kept, bytes):
                kept = kept.decode()
            if isinstance(kept, str) and kept:
                correlation_id.set(kept)
                return kept
        except Exception as exc:
            logger.warning(
                "Could not read the correlation ID of a %s", kind,
                extra={"error_class": type(exc).__name__},
            )
    return new_correlation_id()
