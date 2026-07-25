"""Structured JSON logging configuration for Echo."""

import json
import logging
import sys
import uuid
from contextvars import ContextVar
from datetime import datetime, timezone

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
        for key in ("segment_id", "user_id", "duration_ms", "step"):
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
