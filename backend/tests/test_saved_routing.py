"""Requests about Saved reach the agent, by chat and by voice; with the camera, "save
this" takes the photo and saves it once it is analysed."""

import pytest

from app.actions import availability
from app.routers import query as q
from tests.test_routines_agent import _IntentLLM


@pytest.mark.parametrize("connected", [[], ["gmail"]])
async def test_a_save_goes_to_the_agent(connected):
    llm = _IntentLLM({"saved": True, "needs_apps": False, "apps": []})

    route = await availability.route_request(llm, "tienimi da parte questo libro", [], connected)

    assert route.kind == "agent" and route.save is False
    assert '"saved"' in llm.call_log[0][0].content


async def test_save_this_with_the_camera_takes_the_photo_to_save_it():
    llm = _IntentLLM({"camera": True, "saved": True, "needs_apps": False, "apps": []})

    route = await availability.route_request(llm, "salva questa etichetta", [], [], camera=True)

    assert route.kind == "photo" and route.save is True


async def test_a_photo_question_is_not_a_save():
    llm = _IntentLLM({"camera": True, "needs_apps": False, "apps": []})

    route = await availability.route_request(llm, "cos'è questo?", [], [], camera=True)

    assert route.kind == "photo" and route.save is False


async def test_without_the_camera_a_save_about_a_photo_is_the_agents():
    # Chat never takes a photo: the agent attaches the thread's last one
    llm = _IntentLLM({"camera": True, "saved": True, "needs_apps": False, "apps": []})

    route = await availability.route_request(llm, "salva questa foto nei vini", [], [])

    assert route.kind == "agent"


@pytest.mark.parametrize(
    "text",
    [
        "Ricordati dove ho parcheggiato",
        "salvami questo vino",
        "quanto ho speso questa settimana?",
        "How much did I spend this month?",
        "Save this book Giulia told me about",
        "ho trovato la macchina, toglila",
    ],
)
def test_saves_are_checked_for_tools_in_chat(text):
    assert q.might_need_tools(text, [])
