"""People are only names said as names: Echo and the user's assistants are not people, and
a word the speech-to-text misheard ("Siems five years", said "since five years") is not one
either."""

import uuid

from app.models.assistant import Assistant
from app.services.analysis_pipeline import assistant_names, extract_entities
from tests.conftest import TEST_USER_ID
from tests.mocks import MockLLMService


class _LLM(MockLLMService):
    def __init__(self, entities):
        super().__init__()
        self.entities = entities

    async def complete_json(self, messages, temperature=0.1):
        self.call_log.append(messages)
        return {"entities": self.entities}


async def test_echo_and_the_assistants_are_not_people():
    llm = _LLM([
        {"type": "person", "name": "Echo", "metadata": {}},
        {"type": "person", "name": "coach fit", "metadata": {}},
        {"type": "person", "name": "Luca", "metadata": {}},
        {"type": "note", "name": "Coach Fit dice di correre", "metadata": {}},
    ])

    entities = await extract_entities(
        llm, "[Tu] Coach Fit, domani corro con Luca.", uuid.uuid4(), uuid.uuid4(),
        uuid.uuid4(), not_people=["Coach Fit"],
    )

    assert [(e.entity_type, e.name) for e in entities] == [
        ("person", "Luca"), ("note", "Coach Fit dice di correre"),
    ]
    prompt = llm.call_log[0][0].content
    assert "Coach Fit" in prompt and "non sono persone" in prompt


async def test_the_prompt_asks_for_names_said_as_names():
    llm = _LLM([])

    await extract_entities(llm, "[You] Siems five years.", uuid.uuid4(), None, uuid.uuid4())

    prompt = llm.call_log[0][0].content
    assert "Nel dubbio non è una persona" in prompt


async def test_the_users_assistant_names(db_session):
    for name in ("Coach Fit", "Dieta"):
        db_session.add(Assistant(
            user_id=TEST_USER_ID, name=name, emoji="🏃", instructions="x",
        ))
    db_session.add(Assistant(user_id=uuid.uuid4(), name="Altrui", emoji="x", instructions="x"))
    await db_session.commit()

    assert sorted(await assistant_names(db_session, TEST_USER_ID)) == ["Coach Fit", "Dieta"]
