"""The wake phrase evaluation set: Echo's own speech where no candidate phrase was said."""

import csv
import uuid
from datetime import datetime, timedelta, timezone

from app.cli import export_wake_eval as export
from app.models.segment import Segment
from app.models.transcription import Transcription
from tests.conftest import TEST_USER_ID, test_session


async def _said(db, tmp_path, text: str, minutes_ago: int) -> Segment:
    audio = tmp_path / f"{uuid.uuid4()}.adpcm"
    audio.write_bytes(text.encode())
    at = datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)
    segment = Segment(
        id=uuid.uuid4(), user_id=TEST_USER_ID, received_at=at, recorded_at=at,
        duration_ms=3000, audio_path=str(audio), transcription_status="completed",
    )
    db.add(segment)
    db.add(Transcription(
        segment_id=segment.id, text=text, language="it", stt_provider="deepgram", stt_model="nova-3"
    ))
    await db.commit()
    return segment


async def test_export_keeps_only_audio_without_a_candidate(db_session, tmp_path, monkeypatch):
    monkeypatch.setattr(export, "segment_to_wav", lambda data: b"WAV" + data)
    home = await _said(db_session, tmp_path, "[You] andiamo a casa", 3)
    await _said(db_session, tmp_path, "[You] hey Jarvis accendi la luce", 2)
    echo = await _said(db_session, tmp_path, "[You] Ehi Echo, che ore sono", 1)
    out = tmp_path / "eval"

    written = await export.export_wake_eval(out, session_factory=test_session)

    assert written == 2
    rows = list(csv.DictReader(open(out / "labels.csv")))
    assert [row["file"] for row in rows] == [f"{echo.id}.wav", f"{home.id}.wav"]
    assert (out / f"{home.id}.wav").read_bytes() == b"WAV[You] andiamo a casa"
    assert rows[0]["duration_ms"] == "3000"


async def test_the_limit_takes_the_newest(db_session, tmp_path, monkeypatch):
    monkeypatch.setattr(export, "segment_to_wav", lambda data: data)
    await _said(db_session, tmp_path, "[You] la prima", 2)
    newest = await _said(db_session, tmp_path, "[You] la seconda", 1)

    written = await export.export_wake_eval(tmp_path / "eval", limit=1, session_factory=test_session)

    assert written == 1
    assert (tmp_path / "eval" / f"{newest.id}.wav").exists()
