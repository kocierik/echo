"""Compare speech-to-text services on your own recordings.

    python -m evals.stt collect [--limit 50]
    python -m evals.stt run --providers deepgram:nova-3,openai:gpt-transcribe

`collect` saves transcribed segments whose audio is still on disk (completed audio is
deleted after COMPLETED_AUDIO_RETENTION_HOURS) to evals/data/stt: the WAV, the text as
a reference (a correction made in the app wins and marks it verified) and its origin.
Correct the *.ref.txt files by hand before trusting the numbers. `run` transcribes
every saved clip with each service and reports word error rate, time and cost.
The folder is git-ignored: it holds your voice and the people around you.
"""

import argparse
import asyncio
import json
import time
import uuid
from pathlib import Path

from sqlalchemy import select

from app.core.config import settings
from app.core.database import async_session
from app.models import Segment, Transcription, TranscriptionEdit
from app.services.adpcm_decoder import adpcm_to_wav
from app.services.stt_deepgram import DeepgramSTTService
from app.services.stt_openai import OpenAISTTService
from app.services.transcription_enhancer import build_stt_context, clean_transcription
from evals.scoring import normalize_words, word_error_rate

DATA = Path(__file__).parent / "data" / "stt"

# List prices per minute (October 2026): check the providers' pages before deciding
PRICE_PER_MINUTE = {
    "deepgram:nova-3": 0.0043,
    "openai:gpt-4o-transcribe": 0.006,
    "openai:gpt-4o-mini-transcribe": 0.003,
    "openai:gpt-transcribe": 0.0045,
}


def _strip_speaker(text: str) -> str:
    for prefix in ("[Tu] ", "[Altri] ", "[You] ", "[Others] "):
        if text.startswith(prefix):
            return text[len(prefix) :]
    return text


async def collect(limit: int) -> None:
    DATA.mkdir(parents=True, exist_ok=True)
    saved = 0
    async with async_session() as db:
        rows = await db.execute(
            select(Segment, Transcription)
            .join(Transcription, Transcription.segment_id == Segment.id)
            .where(Segment.audio_path.is_not(None))
            .order_by(Segment.recorded_at.desc())
            .limit(limit * 4)
        )
        for segment, transcription in rows.all():
            if saved >= limit:
                break
            audio = Path(segment.audio_path)
            if not audio.exists() or (DATA / f"{segment.id}.wav").exists():
                continue
            edit = (
                await db.execute(
                    select(TranscriptionEdit)
                    .where(TranscriptionEdit.transcription_id == transcription.id)
                    .order_by(TranscriptionEdit.created_at.desc())
                    .limit(1)
                )
            ).scalar_one_or_none()
            reference = _strip_speaker(edit.new_text if edit else transcription.text)
            if not normalize_words(reference):
                continue
            (DATA / f"{segment.id}.wav").write_bytes(adpcm_to_wav(audio.read_bytes()))
            (DATA / f"{segment.id}.ref.txt").write_text(reference + "\n", encoding="utf-8")
            (DATA / f"{segment.id}.json").write_text(
                json.dumps(
                    {
                        "user_id": str(segment.user_id),
                        "duration_ms": segment.duration_ms,
                        "recorded_at": segment.recorded_at.isoformat(),
                        "transcribed_by": f"{transcription.stt_provider}:{transcription.stt_model}",
                        "verified": edit is not None,
                    },
                    indent=2,
                ),
                encoding="utf-8",
            )
            saved += 1
    print(f"Saved {saved} clips to {DATA} (references are the current transcripts:")
    print("correct the *.ref.txt files that are wrong, then run the comparison).")


def _service(spec: str):
    provider, _, model = spec.partition(":")
    if provider == "deepgram":
        service = DeepgramSTTService()
    elif provider == "openai":
        service = OpenAISTTService()
    else:
        raise SystemExit(f"Unknown provider {provider!r} (deepgram or openai)")
    service.model = model or service.model
    return service


async def run(specs: list[str], hints: bool) -> None:
    clips = sorted(DATA.glob("*.wav"))
    if not clips:
        raise SystemExit(f"No clips in {DATA}: run `python -m evals.stt collect` first")
    contexts: dict[str, object] = {}
    print(f"{len(clips)} clips, hints {'on' if hints else 'off'}\n")
    print(f"{'service':32} {'WER':>6} {'verified WER':>13} {'s/clip':>7} {'$/hour':>7}")
    for spec in specs:
        service = _service(spec)
        errors, verified_errors, seconds, minutes = [], [], 0.0, 0.0
        for clip in clips:
            meta = json.loads(clip.with_suffix(".json").read_text(encoding="utf-8"))
            reference = clip.with_suffix(".ref.txt").read_text(encoding="utf-8")
            user_id = meta["user_id"]
            if hints and user_id not in contexts:
                async with async_session() as db:
                    contexts[user_id] = await build_stt_context(db, uuid.UUID(user_id))
            context = contexts.get(user_id)
            start = time.perf_counter()
            result = await service.transcribe(
                clip.read_bytes(),
                language=settings.stt_language,
                prompt=(context.prompt or None) if context else None,
                keyterms=context.keyterms if context else None,
            )
            seconds += time.perf_counter() - start
            minutes += meta["duration_ms"] / 60000
            error = word_error_rate(reference, clean_transcription(result.text))
            errors.append(error)
            if meta["verified"]:
                verified_errors.append(error)
        verified = (
            f"{sum(verified_errors) / len(verified_errors):12.1%}"
            if verified_errors
            else "           -"
        )
        price = PRICE_PER_MINUTE.get(spec)
        hourly = f"{price * 60:7.2f}" if price else "      ?"
        print(
            f"{spec:32} {sum(errors) / len(errors):6.1%} {verified} "
            f"{seconds / len(clips):7.2f} {hourly}"
        )
    print("\nWER: share of reference words missed, wrong or added (lower is better).")


async def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    commands = parser.add_subparsers(dest="command", required=True)
    collect_parser = commands.add_parser("collect")
    collect_parser.add_argument("--limit", type=int, default=50)
    run_parser = commands.add_parser("run")
    run_parser.add_argument(
        "--providers", required=True, help="e.g. deepgram:nova-3,openai:gpt-transcribe"
    )
    run_parser.add_argument("--no-hints", action="store_true", help="without known names")
    args = parser.parse_args()
    if args.command == "collect":
        await collect(args.limit)
    else:
        await run(args.providers.split(","), hints=not args.no_hints)


if __name__ == "__main__":
    asyncio.run(main())
