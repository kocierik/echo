"""The phone's place, read only when a save asks for it (`get_location` device command)."""

import asyncio

from app.actions.phone_provider import record_phone_result
from app.services import phone_location
from app.services.device_commands import take_device_commands
from tests.conftest import TEST_USER_ID
from tests.test_phone_actions import WaitingRedis

PLACE = {"latitude": 45.4642, "longitude": 9.19, "accuracy_m": 15, "address": "Via Roma 12, Milano"}


async def _phone_answers(redis, result: dict, *, answer=True) -> dict:
    """What the app does: picks the command up and, when `answer`, posts its result."""
    for _ in range(200):
        if commands := await take_device_commands(redis, TEST_USER_ID, 0):
            break
        await asyncio.sleep(0.01)
    [command] = commands
    if answer:
        assert await record_phone_result(redis, TEST_USER_ID, command["id"], result)
    return command


async def test_the_phone_gives_its_place():
    redis = WaitingRedis()
    phone = asyncio.create_task(_phone_answers(redis, {"ok": True, "data": PLACE}))

    answer = await phone_location.ask_phone_location(redis, TEST_USER_ID, item_id="i1", wait_s=2)
    command = await phone

    assert command["type"] == "get_location" and command["item_id"] == "i1"
    assert answer.error is None
    assert answer.place == {
        "latitude": 45.4642, "longitude": 9.19, "accuracy_m": 15.0,
        "address": "Via Roma 12, Milano",
    }


async def test_no_phone_picking_it_up_is_no_phone():
    answer = await phone_location.ask_phone_location(WaitingRedis(), TEST_USER_ID, wait_s=0.2)

    assert answer.place is None and answer.error == "no_phone"


async def test_picked_up_without_an_answer_is_a_timeout():
    redis = WaitingRedis()
    phone = asyncio.create_task(_phone_answers(redis, {}, answer=False))

    answer = await phone_location.ask_phone_location(redis, TEST_USER_ID, wait_s=0.5)
    await phone

    assert answer.error == "timeout"


async def test_the_phone_says_why_it_could_not():
    redis = WaitingRedis()
    phone = asyncio.create_task(
        _phone_answers(redis, {"ok": False, "error": "background"})
    )

    answer = await phone_location.ask_phone_location(redis, TEST_USER_ID, wait_s=2)
    await phone

    assert answer.place is None and answer.error == "background"


async def test_a_place_out_of_range_is_unavailable():
    redis = WaitingRedis()
    phone = asyncio.create_task(
        _phone_answers(redis, {"ok": True, "data": {"latitude": 123, "longitude": 9}})
    )

    answer = await phone_location.ask_phone_location(redis, TEST_USER_ID, wait_s=2)
    await phone

    assert answer.error == "unavailable"


def test_a_place_without_an_address_keeps_the_coordinates():
    assert phone_location.valid_place({"latitude": 1, "longitude": 2}) == {
        "latitude": 1.0, "longitude": 2.0, "accuracy_m": None, "address": None,
    }
    assert phone_location.valid_place({"latitude": "x", "longitude": 2}) is None
