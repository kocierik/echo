"""New assistant by answering questions: a template's own (no model call), or ones made
for what an assistant from scratch is for; the answers become a proposal reviewed in the
editor. ✨ Improve rewrites a few words of instructions."""

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


async def test_a_template_asks_its_own_questions_without_the_model(client, auth_headers, llm):
    await _italian()

    response = await _post(client, auth_headers, "questions", {"template": "diet"})

    assert response.status_code == 200
    questions = response.json()["questions"]
    assert [q["id"] for q in questions] == ["goal", "limits", "help"]
    assert "Allergie" in questions[1]["text"] and questions[1]["multi"] is True
    assert "Vegetariano" in questions[1]["options"]
    assert llm.asked == []


@pytest.mark.parametrize("key", list(assistant_builder.QUESTIONS))
def test_every_template_has_questions_in_both_languages(key):
    for lang in ("it", "en"):
        questions = assistant_builder.QUESTIONS[key][lang]
        assert 2 <= len(questions) <= assistant_builder.MAX_QUESTIONS
        assert all(q["text"] for q in questions)


async def test_from_scratch_the_questions_are_made_for_the_topic(client, auth_headers, llm):
    llm.answer = {"questions": [
        {"text": "Che distanza vuoi correre?", "options": ["10 km", "Mezza", "Maratona"],
         "hint": "Es. maratona di Roma"},
        {"text": "  Quanti   giorni ti alleni? ", "options": [f"{i}" for i in range(9)]},
        {"text": ""},
        "not a question",
        {"text": "Hai dolori o infortuni?", "options": [], "multi": True},
    ]}

    response = await _post(
        client, auth_headers, "questions", {"topic": "preparare una maratona"}
    )

    questions = response.json()["questions"]
    assert [q["text"] for q in questions] == [
        "Che distanza vuoi correre?", "Quanti giorni ti alleni?", "Hai dolori o infortuni?",
    ]
    assert len(questions[1]["options"]) == assistant_builder.MAX_OPTIONS
    assert questions[2]["multi"] is True
    assert "preparare una maratona" in llm.asked[0][-1].content


async def test_from_scratch_the_model_down_gives_the_generic_questions(client, auth_headers, llm):
    llm.fail = True

    response = await _post(client, auth_headers, "questions", {"topic": "il mio cane"})

    assert response.status_code == 200
    assert [q["id"] for q in response.json()["questions"]] == ["goal", "keep", "tone"]


async def test_questions_need_a_template_or_a_topic(client, auth_headers, llm):
    assert (await _post(client, auth_headers, "questions", {})).status_code == 422
    assert (
        await _post(client, auth_headers, "questions", {"template": "astrology"})
    ).status_code == 422


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
