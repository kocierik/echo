"""Model usage per user and day, so the cost of a day of Echo can be known.

Whoever owns the current work is in `usage_owner`: the key's user during a request
(core/auth.py) and the row's user in each worker job (`with owned_by(...)`). The model
services call `record_usage` after each call; a failed write is logged and never fails
the work it measures.
"""

import contextlib
import io
import logging
import math
import uuid
import wave
from collections.abc import Iterator
from contextvars import ContextVar
from datetime import datetime, timezone

from sqlalchemy.dialects.postgresql import insert

from app.core.database import async_session
from app.models.llm_usage import LlmUsage

logger = logging.getLogger(__name__)

usage_owner: ContextVar[uuid.UUID | None] = ContextVar("usage_owner", default=None)

# Kinds already reported as unowned, so a gap is logged once per process, not per call
_warned_unowned: set[str] = set()


@contextlib.contextmanager
def owned_by(user_id: uuid.UUID | None) -> Iterator[None]:
    """The work inside the block is counted for `user_id`."""
    token = usage_owner.set(user_id)
    try:
        yield
    finally:
        usage_owner.reset(token)


async def record_usage(
    kind: str,
    model: str,
    *,
    input_units: int = 0,
    output_units: int = 0,
    cached_units: int = 0,
    session_factory=None,
) -> None:
    """Adds one call and its units to today's row (UTC) for the owner, kind and model."""
    owner = usage_owner.get()
    if owner is None and kind not in _warned_unowned:
        _warned_unowned.add(kind)
        logger.warning("Model usage with no owner: %s (%s)", kind, model)
    statement = insert(LlmUsage).values(
        id=uuid.uuid4(),
        user_id=owner,
        day=datetime.now(timezone.utc).date(),
        kind=kind,
        model=model,
        calls=1,
        input_units=input_units,
        output_units=output_units,
        cached_units=cached_units,
    )
    statement = statement.on_conflict_do_update(
        constraint="uq_llm_usage_day",
        set_={
            "calls": LlmUsage.calls + 1,
            "input_units": LlmUsage.input_units + statement.excluded.input_units,
            "output_units": LlmUsage.output_units + statement.excluded.output_units,
            "cached_units": LlmUsage.cached_units + statement.excluded.cached_units,
        },
    )
    try:
        async with (session_factory or async_session)() as db:
            await db.execute(statement)
            await db.commit()
    except Exception:
        logger.warning("Could not record model usage (%s, %s)", kind, model, exc_info=True)


def wav_seconds(wav_bytes: bytes) -> int:
    """Whole seconds of audio in a WAV, rounded up (what transcription is billed by)."""
    try:
        with wave.open(io.BytesIO(wav_bytes), "rb") as audio:
            return math.ceil(audio.getnframes() / audio.getframerate())
    except Exception:
        return 0
