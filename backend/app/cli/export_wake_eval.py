"""Echo's own speech, as WAV files, to measure how often a wake phrase model fires where
nobody said it (firmware/tools/wake_eval.py).

    python -m app.cli.export_wake_eval --out /app/.wake_eval [--user <id>] [--limit 2000]

Copies the user's recordings: run it only with their consent. Segments whose transcript
names a candidate phrase are left out, so everything exported is a negative.
"""

import argparse
import asyncio
import csv
import logging
import re
import uuid
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.services.segment_audio import segment_to_wav

logger = logging.getLogger(__name__)

# The names of the ready-made phrases being compared (plan 2026-11-13, decision 6)
CANDIDATES = re.compile(r"jarvis|giarvis|jervis|mycroft|maicroft|nabu", re.IGNORECASE)


async def export_wake_eval(
    out: Path, *, limit: int = 2000, user_id: uuid.UUID | None = None, session_factory=None
) -> int:
    """Writes `<segment id>.wav` and labels.csv (file, recorded_at, duration_ms), newest
    first; the number of files written."""
    if session_factory is None:
        from app.core.database import async_session

        session_factory = async_session
    from app.models.segment import Segment

    out.mkdir(parents=True, exist_ok=True)
    written = 0
    async with session_factory() as db:
        query = (
            select(Segment)
            .options(selectinload(Segment.transcription))
            .where(Segment.transcription_status == "completed")
            .where(Segment.audio_path.is_not(None))
            .order_by(Segment.recorded_at.desc())
        )
        if user_id is not None:
            query = query.where(Segment.user_id == user_id)
        with open(out / "labels.csv", "w", newline="") as labels:
            rows = csv.writer(labels)
            rows.writerow(["file", "recorded_at", "duration_ms"])
            for segment in (await db.scalars(query)).all():
                if written >= limit:
                    break
                text = segment.transcription.text if segment.transcription else ""
                if not text or CANDIDATES.search(text):
                    continue
                try:
                    wav = segment_to_wav(Path(segment.audio_path).read_bytes())
                except Exception:
                    logger.warning("Segment %s skipped: audio unreadable", segment.id)
                    continue
                name = f"{segment.id}.wav"
                (out / name).write_bytes(wav)
                rows.writerow([name, segment.recorded_at.isoformat(), segment.duration_ms])
                written += 1
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=2000)
    parser.add_argument("--user", type=uuid.UUID, default=None)
    args = parser.parse_args()
    written = asyncio.run(export_wake_eval(args.out, limit=args.limit, user_id=args.user))
    print(f"{written} segments exported to {args.out}")


if __name__ == "__main__":
    main()
