"""To-dos are asked of Echo; from conversations, by default, none at all. With
CONVERSATION_PROMISES on, only the promises, the user's or made to them; any other to-do
the model returns is dropped."""

import uuid

from app.core.config import settings
from app.services.analysis_pipeline import extract_entities
from tests.mocks import MockLLMService


class _LLM(MockLLMService):
    def __init__(self, entities):
        super().__init__()
        self.entities = entities

    async def complete_json(self, messages, temperature=0.1):
        self.call_log.append(messages)
        return {"entities": self.entities}


_ENTITIES = [
    {"type": "task", "name": "Mandare le slide",
     "metadata": {"done": False, "promise": True, "promise_to": "Luca"}},
    {"type": "person", "name": "Luca", "metadata": {}},
]


async def test_by_default_a_conversation_makes_no_to_do():
    entities = await extract_entities(
        _LLM(_ENTITIES), "[Tu] Ok Luca, ti giro le slide stasera.",
        uuid.uuid4(), uuid.uuid4(), uuid.uuid4(), known_people=["Luca"],
    )

    # The person stays; the promise is not a to-do unless the user asks Echo
    assert [(e.entity_type, e.name) for e in entities] == [("person", "Luca")]


async def test_only_promises_and_expected_things_become_tasks(monkeypatch):
    monkeypatch.setattr(settings, "conversation_promises", True)
    llm = _LLM([
        {"type": "task", "name": "Comprare il latte", "metadata": {"done": False}},
        {"type": "task", "name": "Mandare il preventivo", "metadata": {"promise": "yes"}},
        {"type": "task", "name": "Mandare le slide",
         "metadata": {"done": False, "promise": True, "promise_to": "Luca"}},
        {"type": "task", "name": "Foto della cena",
         "metadata": {"done": False, "expected": True, "expected_from": "Luca"}},
        {"type": "person", "name": "Luca", "metadata": {}},
    ])

    entities = await extract_entities(
        llm, "[Tu] Ok Luca, ti giro le slide stasera.", uuid.uuid4(), uuid.uuid4(), uuid.uuid4(),
        known_people=["Luca"],
    )

    assert [(e.entity_type, e.name) for e in entities] == [
        ("task", "Mandare le slide"), ("task", "Foto della cena"), ("person", "Luca"),
    ]
    prompt = llm.call_log[0][0].content
    assert "SOLO le promesse" in prompt and "Nel dubbio non è una promessa" in prompt
