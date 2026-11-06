"""The cities the user stays in are hints for the speech-to-text: an Italian says "a Nizza"
where the address says "Nice", and without the hint it was heard as "Anit"."""

import uuid
from datetime import datetime, timedelta, timezone

from app.models.place_visit import PlaceVisit
from app.services.transcription_enhancer import build_stt_context, place_terms
from tests.conftest import TEST_USER_ID


async def _visit(db, address, hours_ago=1):
    at = datetime.now(timezone.utc) - timedelta(hours=hours_ago)
    db.add(PlaceVisit(
        id=uuid.uuid4(), user_id=TEST_USER_ID, key=f"t:{uuid.uuid4()}", arrived_at=at,
        left_at=at + timedelta(minutes=30), latitude=43.7, longitude=7.26, address=address,
        source="ios",
    ))


async def test_the_cities_stayed_in_with_their_italian_names(db_session):
    for hours in range(3):
        await _visit(db_session, f"Rue Trachel {hours}, Nice", hours)
    await _visit(db_session, "Via Marconi 30, Bologna")
    await _visit(db_session, "Boulevard Victor Hugo, 06000 Nice")
    await db_session.commit()

    terms = await place_terms(db_session, TEST_USER_ID)
    context = await build_stt_context(db_session, TEST_USER_ID)

    # The most visited first, by the name said and by the name written
    assert terms == ["Nizza", "Nice", "Bologna"]
    assert {"Nizza", "Bologna"} <= set(context.keyterms)
    assert context.keyterms[0] == "Echo"


async def test_no_places_no_terms(db_session):
    assert await place_terms(db_session, TEST_USER_ID) == []
