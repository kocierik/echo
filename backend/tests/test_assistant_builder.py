"""New assistant from a description: Echo writes the proposal (a template, when chosen, is
its start), the user tries it before saving. ✨ Improve rewrites a few words of
instructions."""

import pytest

from app.main import app
from app.models.user import User
from app.routers import assistants as assistants_router
from app.services import assistant_builder
from tests.conftest import TEST_USER_ID, test_session


class _Llm:
    def __init__(self, answer=None, fail=False):
        self.answer = answer or {}
        self.fail = fail
        self.asked: list = []

    async def complete_json(self, messages, temperature=0.1):
        self.asked.append(messages)
        if self.fail:
            raise RuntimeError("model down")
        return self.answer


@pytest.fixture
def llm():
    fake = _Llm()
    app.dependency_overrides[assistants_router.builder_llm] = lambda: fake
    yield fake
    app.dependency_overrides.pop(assistants_router.builder_llm, None)


async def _italian():
    async with test_session() as db:
        db.add(User(id=TEST_USER_ID, email="erik@example.com", password_hash="x", language="it"))
        await db.commit()


async def _post(client, auth_headers, path, body):
    return await client.post(f"/api/assistants/{path}", headers=auth_headers, json=body)












async def test_the_answers_become_a_proposal_from_the_template(client, auth_headers, llm):
    await _italian()
    llm.answer = {
        "name": "Dieta vegetariana",
        "emoji": "food",
        "instructions": "Sei il mio coach per l'alimentazione vegetariana.",
        "notes": ["Obiettivo: più energia", "- Vegetariano", "", "Niente funghi"],
    }

    response = await _post(client, auth_headers, "compose", {
        "template": "diet",
        "answers": [
            {"question": "Qual è il tuo obiettivo?", "answer": "Più energia"},
            {"question": "Allergie?", "answer": "Vegetariano, niente funghi"},
        ],
    })

    assert response.status_code == 200
    proposal = response.json()
    assert proposal["name"] == "Dieta vegetariana"
    # A word is not an emoji: the template's
    assert proposal["emoji"] == "🥗"
    assert proposal["notes"] == "- Obiettivo: più energia\n- Vegetariano\n- Niente funghi"
    prompt = llm.asked[0][-1].content
    assert "Coach" in prompt or "coach" in prompt
    assert "Vegetariano, niente funghi" in prompt
    assert "Italian" in llm.asked[0][0].content


async def test_a_proposal_keeps_within_the_limits(client, auth_headers, llm):
    llm.answer = {
        "name": "x" * 100,
        "emoji": "🏃",
        "instructions": "y" * 5000,
        "notes": [f"riga {i} " + "z" * 150 for i in range(10)],
    }

    proposal = (await _post(client, auth_headers, "compose", {"topic": "corsa"})).json()

    assert len(proposal["name"]) <= 40
    assert len(proposal["instructions"]) <= 2000
    assert len(proposal["notes"]) <= assistant_builder.PROPOSED_NOTES
    assert proposal["emoji"] == "🏃"


async def test_a_proposal_the_model_cannot_write_says_try_again(client, auth_headers, llm):
    llm.fail = True

    response = await _post(client, auth_headers, "compose", {"topic": "corsa"})

    assert response.status_code == 503
    assert "try again" in response.json()["detail"]


async def test_improve_rewrites_a_few_words(client, auth_headers, llm):
    llm.answer = {"instructions": "Sei il mio coach di corsa: annota ogni uscita."}

    response = await _post(
        client, auth_headers, "improve", {"name": "Corsa", "instructions": "aiutami a correre"}
    )

    assert response.json() == {"instructions": "Sei il mio coach di corsa: annota ogni uscita."}
    assert "aiutami a correre" in llm.asked[0][-1].content
    too_short = await _post(client, auth_headers, "improve", {"instructions": "a"})
    assert too_short.status_code == 422


async def test_described_in_words_it_is_written_without_questions(client, auth_headers, llm):
    llm.answer = {
        "name": "Mezza di Bologna", "emoji": "🏃",
        "instructions": "Sei il mio coach per la mezza di Bologna.",
        "notes": ["Corsa: martedì, giovedì e domenica"],
    }
    description = "Seguimi per la mezza di Bologna, corro mar/gio/dom. " + "x" * 600

    response = await _post(client, auth_headers, "compose", {"topic": description})

    assert response.status_code == 200
    assert response.json()["name"] == "Mezza di Bologna"
    # A long description reaches the model whole (not cut at 300)
    assert "x" * 600 in llm.asked[0][-1].content
    assert (await _post(client, auth_headers, "compose", {})).status_code == 422


async def test_try_it_answers_as_the_assistant_would(client, auth_headers, llm):
    class _Chat(_Llm):
        async def complete(self, messages, temperature=0.3):
            self.asked.append(messages)
            from app.services.llm_base import LLMResponse

            return LLMResponse(content="Domenica fai il lungo: 14 km tranquilli.", model="m")

    chat = _Chat()
    app.dependency_overrides[assistants_router.builder_llm] = lambda: chat

    response = await _post(client, auth_headers, "try", {
        "name": "Mezza di Bologna", "emoji": "🏃",
        "instructions": "Sei il mio coach per la mezza.", "notes": "- Ginocchio destro",
        "question": "cosa faccio domenica?",
    })

    assert response.json() == {"answer": "Domenica fai il lungo: 14 km tranquilli."}
    system = chat.asked[0][0].content
    assert "Sei il mio coach per la mezza." in system and "Ginocchio destro" in system
    assert chat.asked[0][-1].content == "cosa faccio domenica?"
    empty = await _post(client, auth_headers, "try", {"question": " "})
    assert empty.status_code == 422
