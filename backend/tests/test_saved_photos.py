""""Echo, save this" with the camera: the photo is taken, analysed, then saved by the
agent with what the vision model read; the thread shows the photo with the save's answer."""

import uuid
from datetime import datetime, timezone

from sqlalchemy import select

from app.models import ChatSession, Photo
from app.models.saved import SavedItem
from app.services import photos as photo_service
from app.services import saved
from app.workers import photos as photo_worker
from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService
from tests.test_photos import JPEG, Embeddings, VisionLLM, _last_voice_message
from tests.test_routines_agent import _call, _ScriptedLLM, _text

LABEL = {
    "answer": "È un Barolo DOCG 2019 della Cantina Rinaldi.",
    "description": "Etichetta di vino: Barolo DOCG 2019, Cantina Rinaldi, 14,5%.",
    "title": "Etichetta Barolo",
}


async def _voice_photo(db, question: str, *, save: bool) -> Photo:
    """A photo a voice request took, uploaded and waiting for the vision model."""
    session = ChatSession(
        id=uuid.uuid4(), user_id=TEST_USER_ID, title="Echo", kind="voice", messages=[]
    )
    db.add(session)
    photo = Photo(
        id=uuid.uuid4(), user_id=TEST_USER_ID, status="received", source="voice",
        question=question, chat_session_id=session.id, image=JPEG,
        captured_at=datetime.now(timezone.utc),
    )
    db.add(photo)
    await db.flush()
    session.messages = [{
        "role": "user", "content": question, "photo_id": str(photo.id), "source": "voice",
        **({"save": True} if save else {}),
    }]
    await db.commit()
    return photo


def _saver(llm):
    async def save(db, photo):
        return await photo_worker.save_photo_request(
            db, photo, llm=llm, embedding_service=MockEmbeddingService()
        )

    return save


async def test_a_photo_to_save_is_saved_with_what_echo_read(db_session):
    photo = await _voice_photo(db_session, "salvami questo vino", save=True)
    agent = _ScriptedLLM([
        _call("ECHO_SAVE_ITEM", list="Vini", title="Barolo 2019",
              fields={"vintage": "2019", "producer": "Cantina Rinaldi"}),
        _text("Salvato nei Vini: Barolo 2019, Cantina Rinaldi."),
    ])

    done = await photo_service.analyse_photo(
        db_session, photo.id, VisionLLM(LABEL), Embeddings(), save_with=_saver(agent)
    )

    assert done
    [item] = list(await db_session.scalars(select(SavedItem)))
    assert item.photo_id == photo.id and item.list.name == "Vini"
    assert item.conversation_id is not None  # the photo's conversation: the moment
    # The agent knew what the photo shows
    assert "Barolo DOCG 2019" in agent.call_log[0][0].content
    message = await _last_voice_message(db_session)
    assert message["content"] == "Salvato nei Vini: Barolo 2019, Cantina Rinaldi."
    assert message["photo_id"] == str(photo.id)
    assert message["saved"][0]["title"] == "Barolo 2019"
    stored = await db_session.get(Photo, photo.id)
    assert stored.answer == LABEL["answer"]  # follow-ups still start from what it shows


async def test_a_photo_after_parking_updates_the_car(db_session):
    car, _ = await saved.save_item(
        db_session, TEST_USER_ID, list_name="La macchina", title="Macchina",
        place={"latitude": 45.46, "longitude": 9.19, "accuracy_m": 10,
               "address": "Via Roma 12, Milano"},
        latest_only=True, keep_days=7, moment=saved.Moment(source="voice"),
    )
    await db_session.commit()
    photo = await _voice_photo(db_session, "fotografa la colonna per la macchina", save=True)
    agent = _ScriptedLLM([
        _call("ECHO_FIND_ITEMS", list="La macchina"),
        _call("ECHO_UPDATE_ITEM", item_id=str(car.id), fields={"level": "-2", "column": "B4"}),
        _text("Aggiunto alla macchina: piano -2, colonna B4."),
    ])
    column = {"answer": "Piano -2, colonna B4.", "description": "Cartello: P-2 B4.",
              "title": "Colonna parcheggio"}

    await photo_service.analyse_photo(
        db_session, photo.id, VisionLLM(column), Embeddings(), save_with=_saver(agent)
    )

    [only] = list(await db_session.scalars(
        select(SavedItem).execution_options(populate_existing=True)
    ))
    assert only.id == car.id
    assert only.place["address"] == "Via Roma 12, Milano"  # the place is kept
    assert only.photo_id == photo.id and only.fields == {"level": "-2", "column": "B4"}


async def test_a_failing_save_keeps_the_photos_answer(db_session):
    photo = await _voice_photo(db_session, "salvami questo vino", save=True)

    async def broken(db, photo):
        raise RuntimeError("model down")

    assert await photo_service.analyse_photo(
        db_session, photo.id, VisionLLM(LABEL), Embeddings(), save_with=broken
    )

    message = await _last_voice_message(db_session)
    assert message["content"] == LABEL["answer"] and "saved" not in message
    assert list(await db_session.scalars(select(SavedItem))) == []


async def test_a_photo_not_to_save_is_only_answered(db_session):
    photo = await _voice_photo(db_session, "che vino è?", save=False)
    calls = []

    async def saver(db, photo):
        calls.append(photo)
        return "x", {}

    await photo_service.analyse_photo(
        db_session, photo.id, VisionLLM(LABEL), Embeddings(), save_with=saver
    )

    assert calls == []
    assert (await _last_voice_message(db_session))["content"] == LABEL["answer"]
