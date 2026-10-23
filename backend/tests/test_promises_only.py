"""To-dos come from conversations only as promises, the user's or made to them; any other
to-do the model returns is dropped (the user asks Echo for those)."""

import uuid

from app.services.analysis_pipeline import extract_entities
from tests.mocks import MockLLMService


class _LLM(MockLLMService):
    def __init__(self, entities):
        super().__init__()
        self.entities = entities

    async def complete_json(self, messages, temperature=0.1):
        self.call_log.append(messages)
        return {"entities": self.entities}


async def test_only_promises_and_expected_things_become_tasks():
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
        llm, "[Tu] Ok Luca, ti giro le slide stasera.", uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    )

    assert [(e.entity_type, e.name) for e in entities] == [
        ("task", "Mandare le slide"), ("task", "Foto della cena"), ("person", "Luca"),
    ]
    prompt = llm.call_log[0][0].content
    assert "SOLO le promesse" in prompt and "Nel dubbio non è una promessa" in prompt
