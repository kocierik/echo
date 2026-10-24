"""Web search: offered to the model while the user is under the daily cap, each search
counted, the pages it cited handed back."""

import uuid
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy import update

from app.core.config import settings
from app.models.llm_usage import LlmUsage
from app.services import llm_openai, web_search
from app.services.llm_base import LLMMessage
from app.services.usage_report import cost
from tests.conftest import TEST_USER_ID, test_session

ns = SimpleNamespace

MESSAGES = [LLMMessage(role="user", content="che tempo fa domani a Milano?")]
SEARCH = {"type": "web_search"}


class _Stream:
    def __init__(self, items):
        self._items = list(items)

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self._items:
            raise StopAsyncIteration
        return self._items.pop(0)


class _Create:
    def __init__(self, answer):
        self.answer = answer
        self.kwargs = []

    async def __call__(self, **kwargs):
        self.kwargs.append(kwargs)
        return self.answer(kwargs) if callable(self.answer) else self.answer


@pytest.fixture
def recorded(monkeypatch):
    calls = []

    async def record(kind, model, *, input_units=0, output_units=0, cached_units=0, **_):
        calls.append((kind, model, input_units, output_units, cached_units))

    monkeypatch.setattr(llm_openai, "record_usage", record)
    return calls


def _usage():
    return ns(input_tokens=10, output_tokens=5, total_tokens=15,
              input_tokens_details=ns(cached_tokens=0))


def _citation(url, title):
    return ns(type="url_citation", url=url, title=title, start_index=0, end_index=1)


def _searched_output():
    return [
        ns(type="web_search_call", id="ws1", status="completed"),
        ns(type="web_search_call", id="ws2", status="completed"),
        ns(type="message", content=[ns(type="output_text", text="Sole.", annotations=[
            _citation("https://ilmeteo.it/milano", "Meteo Milano"),
            _citation("https://3bmeteo.com/milano", "3B Meteo"),
            _citation("https://ilmeteo.it/milano", "Meteo Milano"),
        ])]),
    ]


def _service(answer):
    service = llm_openai.OpenAIResponsesLLMService("m", kind="llm_query")
    create = _Create(answer)
    service.client = ns(responses=ns(create=create))
    return service, create


async def _searches(units: int) -> None:
    async with test_session() as db:
        db.add(LlmUsage(
            id=uuid.uuid4(), user_id=TEST_USER_ID, day=datetime.now(timezone.utc).date(),
            kind="web_search", model="openai-web-search", calls=1, input_units=units,
        ))
        await db.commit()


async def test_the_tool_is_offered_under_the_cap(monkeypatch):
    monkeypatch.setattr(settings, "web_search_provider", "openai")
    await _searches(4)  # free: 5 a day
    service, _ = _service(None)

    tool = await web_search.search_tool_for(service, TEST_USER_ID, session_factory=test_session)

    assert tool["type"] == "web_search"


async def test_no_tool_at_the_cap(monkeypatch):
    monkeypatch.setattr(settings, "web_search_provider", "openai")
    await _searches(5)
    service, _ = _service(None)

    assert await web_search.search_tool_for(
        service, TEST_USER_ID, session_factory=test_session
    ) is None


async def test_the_cap_is_the_plans(monkeypatch):
    from app.models.user import User

    monkeypatch.setattr(settings, "web_search_provider", "openai")
    async with test_session() as db:
        db.add(User(id=TEST_USER_ID, email="erik@example.com", password_hash="x", plan="plus"))
        await db.commit()
    await _searches(29)  # past free's 5, under plus's 30
    service, _ = _service(None)

    assert await web_search.search_tool_for(service, TEST_USER_ID, test_session) is not None
    async with test_session() as db:
        await db.execute(update(LlmUsage).values(input_units=30))
        await db.commit()
    assert await web_search.search_tool_for(service, TEST_USER_ID, test_session) is None


async def test_no_tool_with_provider_none_or_a_model_that_cannot_search(monkeypatch):
    service, _ = _service(None)
    monkeypatch.setattr(settings, "web_search_provider", "none")
    assert await web_search.search_tool_for(service, TEST_USER_ID, test_session) is None

    monkeypatch.setattr(settings, "web_search_provider", "openai")
    chat = llm_openai.OpenAILLMService("m")
    assert await web_search.search_tool_for(chat, TEST_USER_ID, test_session) is None


async def test_searches_are_counted_and_citations_collected(recorded):
    reply = ns(output_text="Sole.", model="m", usage=_usage(), output=_searched_output())
    service, create = _service(reply)

    response = await service.complete(MESSAGES, hosted_tools=[SEARCH])

    assert SEARCH in create.kwargs[0]["tools"]
    assert ("web_search", "openai-web-search", 2, 0, 0) in recorded
    assert response.citations == [
        {"title": "Meteo Milano", "url": "https://ilmeteo.it/milano"},
        {"title": "3B Meteo", "url": "https://3bmeteo.com/milano"},
    ]


async def test_tools_and_hosted_tools_go_together(recorded):
    reply = ns(output_text="Sole.", model="m", usage=_usage(), output=_searched_output())
    service, create = _service(reply)
    function = {"type": "function", "function": {"name": "t", "parameters": {}}}

    response = await service.complete_with_tools(MESSAGES, [function], hosted_tools=[SEARCH])

    assert [tool["type"] for tool in create.kwargs[0]["tools"]] == ["function", "web_search"]
    assert len(response.citations) == 2
    assert ("web_search", "openai-web-search", 2, 0, 0) in recorded


async def test_a_stream_counts_searches_and_hands_the_citations(recorded):
    events = [
        ns(type="response.web_search_call.completed"),
        ns(type="response.output_text.delta", delta="So"),
        ns(type="response.output_text.delta", delta="le."),
        ns(type="response.completed",
           response=ns(usage=_usage(), output=_searched_output())),
    ]
    service, _ = _service(lambda kwargs: _Stream(events))
    handed = []

    pieces = [
        piece async for piece in service.stream(
            MESSAGES, hosted_tools=[SEARCH], on_citations=handed.append
        )
    ]

    assert pieces == ["So", "le."]
    assert handed == [[
        {"title": "Meteo Milano", "url": "https://ilmeteo.it/milano"},
        {"title": "3B Meteo", "url": "https://3bmeteo.com/milano"},
    ]]
    assert recorded.count(("web_search", "openai-web-search", 2, 0, 0)) == 1


async def test_no_search_no_search_record(recorded):
    reply = ns(output_text="Ciao.", model="m", usage=_usage(), output=[])
    service, _ = _service(reply)

    response = await service.complete(MESSAGES)

    assert [kind for kind, *_ in recorded] == ["llm_query"]
    assert response.citations == []


def test_search_cost():
    assert cost("openai-web-search", 1000, 0, 0) == pytest.approx(10.0)
