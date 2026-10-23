"""The agent's Saved tools: save (with the place or a photo when asked), update, find, sum
and remove, by chat and by voice."""

import asyncio
import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.actions.agent import NO_APPS, run_action_agent
from app.actions.phone_provider import record_phone_result
from app.actions.saved_tools import SavedContext
from app.core.timezone import user_zone
from app.models.action_log import ActionLog
from app.models.chat_session import ChatSession
from app.models.photo import Photo
from app.models.saved import SavedItem
from app.services import saved
from app.services.device_commands import take_device_commands
from tests.conftest import TEST_USER_ID
from tests.mocks import MockEmbeddingService
from tests.test_phone_actions import WaitingRedis
from tests.test_routines_agent import _call, _ScriptedLLM, _text

PLACE = {"latitude": 45.46, "longitude": 9.19, "accuracy_m": 10, "address": "Via Roma 12, Milano"}


async def _run(db, request, llm, context=None, **kwargs):
    return await run_action_agent(
        db, TEST_USER_ID, request, [], session_id=kwargs.pop("session_id", None),
        source="voice", provider=NO_APPS, llm=llm, connected_toolkits=[],
        saved=context or SavedContext(embedding_service=MockEmbeddingService()), **kwargs,
    )


async def _items(db) -> list[SavedItem]:
    return list(await db.scalars(select(SavedItem).where(SavedItem.user_id == TEST_USER_ID)))


def _tool_result(llm) -> str:
    message = llm.call_log[-1][-1]
    assert message.role == "tool"
    return message.content


async def test_the_agent_saves_into_a_new_list_and_says_which(db_session):
    llm = _ScriptedLLM([
        _call("ECHO_SAVE_ITEM", list="Vini", title="Barolo 2019", details="Cantina Rinaldi",
              fields={"vintage": "2019"}, people=["Marco"]),
        _text("Salvato nei Vini: Barolo 2019."),
    ])

    outcome = await _run(db_session, "salvami questo vino, il Barolo 2019 con Marco", llm)
    await db_session.commit()

    [item] = await _items(db_session)
    assert (item.list.name, item.title, item.fields) == ("Vini", "Barolo 2019", {"vintage": "2019"})
    assert item.people == [{"name": "Marco", "id": None}]
    assert item.request_text == "salvami questo vino, il Barolo 2019 con Marco"
    assert outcome.saved == [
        {"id": str(item.id), "title": "Barolo 2019", "list": "Vini", "address": None}
    ]
    assert '"created": true' in _tool_result(llm)
    log = (await db_session.scalars(select(ActionLog))).one()
    assert log.tool == "ECHO_SAVE_ITEM" and log.outcome == "ok"


async def test_the_prompt_names_the_users_lists(db_session):
    await saved.save_item(
        db_session, TEST_USER_ID, list_name="La macchina", title="Macchina",
        latest_only=True, keep_days=7, moment=saved.Moment(),
    )
    llm = _ScriptedLLM([_text("ok")])

    await _run(db_session, "salvami questo libro", llm)

    prompt = llm.call_log[0][0].content
    assert "Saved" in prompt and '"La macchina"' in prompt and "latest only" in prompt
    names = {tool["function"]["name"] for tool in llm.tools_log[0]}
    assert {
        "ECHO_SAVE_ITEM", "ECHO_UPDATE_ITEM", "ECHO_FIND_ITEMS", "ECHO_SUM_ITEMS",
        "ECHO_REMOVE_ITEM",
    } <= names


async def test_saved_tools_are_not_offered_to_a_routine(db_session):
    llm = _ScriptedLLM([_text("ok")])

    await _run(db_session, "ogni mattina il meteo", llm, routine_tools=False)

    names = {tool["function"]["name"] for tool in llm.tools_log[0]}
    assert "ECHO_SAVE_ITEM" not in names


async def _phone(redis, result):
    for _ in range(300):
        if commands := await take_device_commands(redis, TEST_USER_ID, 0):
            break
        await asyncio.sleep(0.01)
    [command] = commands
    await record_phone_result(redis, TEST_USER_ID, command["id"], result)
    return command


async def test_parking_saves_the_phones_place(db_session):
    redis = WaitingRedis()
    phone = asyncio.create_task(_phone(redis, {"ok": True, "data": PLACE}))
    llm = _ScriptedLLM([
        _call("ECHO_SAVE_ITEM", list="La macchina", title="Macchina", with_place=True,
              latest_only=True, keep_days=7),
        _text("Ho salvato la macchina: Via Roma 12, Milano."),
    ])

    outcome = await _run(
        db_session, "ricordati dove ho parcheggiato", llm,
        SavedContext(redis_client=redis, embedding_service=MockEmbeddingService()),
    )
    command = await phone

    [car] = await _items(db_session)
    assert command["item_id"] == str(car.id)
    assert car.place["address"] == "Via Roma 12, Milano"
    assert car.list.latest_only and car.list.keep_days == 7
    assert outcome.saved[0]["address"] == "Via Roma 12, Milano"
    assert "Via Roma 12" in _tool_result(llm)


async def test_without_the_phone_it_is_saved_without_the_place(db_session, monkeypatch):
    monkeypatch.setattr("app.actions.saved_tools.LOCATION_WAIT_S", 0.1)
    llm = _ScriptedLLM([
        _call("ECHO_SAVE_ITEM", list="Posti", title="Questo posto", with_place=True),
        _text("Salvato, ma senza il posto."),
    ])

    await _run(
        db_session, "salvami questo posto", llm,
        SavedContext(redis_client=WaitingRedis(), embedding_service=MockEmbeddingService()),
    )

    [item] = await _items(db_session)
    assert item.place is None
    assert "not saved" in _tool_result(llm) and "Echo app" in _tool_result(llm)


async def _photo(db, session_id, minutes_ago: int, description: str) -> Photo:
    photo = Photo(
        id=uuid.uuid4(), user_id=TEST_USER_ID, status="done", source="app",
        chat_session_id=session_id, description=description,
        created_at=datetime.now(timezone.utc) - timedelta(minutes=minutes_ago),
    )
    db.add(photo)
    await db.flush()
    return photo


async def test_with_photo_takes_the_threads_last_photo_of_the_last_ten_minutes(db_session):
    session = ChatSession(id=uuid.uuid4(), user_id=TEST_USER_ID, title="Echo", kind="voice")
    db_session.add(session)
    await db_session.flush()
    await _photo(db_session, session.id, 30, "Una vecchia foto")
    recent = await _photo(db_session, session.id, 2, "Etichetta: Etna Rosso 2021")
    llm = _ScriptedLLM([
        _call("ECHO_SAVE_ITEM", list="Vini", title="Etna Rosso", with_photo=True),
        _text("Salvato nei Vini."),
    ])

    await _run(
        db_session, "salva questa foto nei vini", llm,
        SavedContext(chat_session_id=session.id, embedding_service=MockEmbeddingService()),
    )

    [item] = await _items(db_session)
    assert item.photo_id == recent.id
    # What the photo shows reaches the model (the level, the vintage)
    assert "Etna Rosso 2021" in _tool_result(llm)


async def test_with_photo_and_no_recent_photo_says_so(db_session):
    session = ChatSession(id=uuid.uuid4(), user_id=TEST_USER_ID, title="Echo", kind="voice")
    db_session.add(session)
    await db_session.flush()
    await _photo(db_session, session.id, 30, "Una vecchia foto")
    llm = _ScriptedLLM([
        _call("ECHO_SAVE_ITEM", list="Vini", title="Etna Rosso", with_photo=True),
        _text("ok"),
    ])

    await _run(
        db_session, "salva la foto nei vini", llm,
        SavedContext(chat_session_id=session.id, embedding_service=MockEmbeddingService()),
    )

    [item] = await _items(db_session)
    assert item.photo_id is None
    assert "no photo" in _tool_result(llm)


async def test_find_sum_update_and_remove(db_session):
    moment = saved.Moment()
    passport, _ = await saved.save_item(
        db_session, TEST_USER_ID, list_name="Dove sono le cose", title="Passaporto",
        details="Nell'armadio", moment=moment,
    )
    for amount in ("12,50", 7.5):
        await saved.save_item(
            db_session, TEST_USER_ID, list_name="Scontrini", title=f"Spesa {amount}",
            fields={"amount": amount}, moment=moment,
        )
    today = datetime.now(user_zone()).date().isoformat()
    llm = _ScriptedLLM([
        _call("ECHO_FIND_ITEMS", query="passaporto"),
        _call("ECHO_UPDATE_ITEM", item_id=str(passport.id), details="Nel cassetto"),
        _call("ECHO_SUM_ITEMS", list="Scontrini", date_from=today, date_to=today),
        _call("ECHO_REMOVE_ITEM", item_id=str(passport.id)),
        _text("Fatto."),
    ])

    outcome = await _run(db_session, "il passaporto è nel cassetto; quanto ho speso oggi?", llm)

    found, updated, total, removed = (m.content for m in llm.call_log[-1] if m.role == "tool")
    assert "Nell'armadio" in found and str(passport.id) in found
    assert "Nel cassetto" in updated
    assert '"EUR": 20.0' in total and '"count": 2' in total
    assert '"removed": "Passaporto"' in removed
    assert sorted(i.title for i in await _items(db_session)) == ["Spesa 12,50", "Spesa 7.5"]
    # Removed in the same answer: no chip for it
    assert outcome.saved == []


async def test_an_unknown_thing_is_not_found(db_session):
    llm = _ScriptedLLM([
        _call("ECHO_REMOVE_ITEM", item_id=str(uuid.uuid4())),
        _text("Non lo trovo."),
    ])

    await _run(db_session, "togli la macchina", llm)

    assert "not found" in _tool_result(llm).lower()


async def test_the_photo_a_voice_request_took_is_attached(db_session):
    photo = await _photo(db_session, None, 0, "Etichetta: Barolo DOCG 2019, Cantina Rinaldi")
    llm = _ScriptedLLM([
        _call("ECHO_SAVE_ITEM", list="Vini", title="Barolo 2019"),
        _text("Salvato nei Vini."),
    ])

    await _run(
        db_session, "salvami questo vino", llm,
        SavedContext(photo_id=photo.id, photo_text=photo.description,
                     embedding_service=MockEmbeddingService()),
    )

    [item] = await _items(db_session)
    assert item.photo_id == photo.id
    # The model is told what the photo shows before it saves
    assert "Barolo DOCG 2019" in llm.call_log[0][0].content


async def test_a_failing_saved_search_leaves_the_session_usable(db_session, monkeypatch):
    """The rest of the answer still reads and writes after Saved could not be searched."""
    from sqlalchemy import text as sql

    from app.services import memory_retrieval

    async def broken(db, *args, **kwargs):
        await db.execute(sql("SELECT * FROM no_such_table"))

    monkeypatch.setattr(memory_retrieval, "find_items", broken)

    assert await memory_retrieval.saved_things(
        db_session, TEST_USER_ID, "il vino", [0.0] * 1536, None, True
    ) == ""
    assert (await db_session.execute(sql("SELECT 1"))).scalar() == 1
