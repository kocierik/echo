import json
import uuid

import pytest

from app.actions import agent as agent_module
from app.actions.agent import (
    MAX_TOOL_RESULT_CHARS,
    SEARCH_MEMORY_TOOL,
    run_action_agent,
)
from app.actions.provider import AccountNotConnectedError, ActionProviderError, ToolResult
from app.core.config import settings
from app.models.action_log import ActionLog
from app.models.pending_action import PendingAction
from app.services.llm_base import LLMResponse, LLMToolCall
from app.services.memory_retrieval import MemoryContext
from tests.fakes.action_provider import FakeActionProvider
from tests.mocks import MockLLMService

USER = uuid.uuid4()
SESSION = uuid.uuid4()


class FakeSession:
    def __init__(self):
        self.rows = []

    def add(self, obj):
        self.rows.append(obj)

    async def flush(self):
        pass

    def of(self, model):
        return [row for row in self.rows if isinstance(row, model)]


class RecordingLLM(MockLLMService):
    """MockLLMService that also records the tools offered on each turn."""

    def __init__(self, responses: list[LLMResponse]):
        super().__init__()
        self.tool_responses = list(responses)
        self.tools_log: list[list[dict]] = []

    async def complete_with_tools(self, messages, tools, temperature=0.2):
        self.tools_log.append(tools)
        return await super().complete_with_tools(messages, tools, temperature)


def _schema(slug: str) -> dict:
    return {
        "type": "function",
        "function": {"name": slug, "description": slug, "parameters": {"type": "object"}},
    }


def _calls(*calls: tuple[str, dict]) -> LLMResponse:
    return LLMResponse(
        content="",
        model="mock",
        tool_calls=[LLMToolCall(f"c{i}", name, args) for i, (name, args) in enumerate(calls)],
    )


def _text(content: str) -> LLMResponse:
    return LLMResponse(content=content, model="mock")


def _tool_messages(messages):
    return [m for m in messages if m.role == "tool"]


def _provider(tools: list[str], results=None, connected=None) -> FakeActionProvider:
    return FakeActionProvider(
        connected=connected if connected is not None else {"gmail"},
        tools={slug: _schema(slug) for slug in tools},
        results=results or {},
    )


async def _run(db, request, provider, llm, history=None, **kwargs):
    return await run_action_agent(
        db, USER, request, history or [],
        session_id=SESSION, source="chat", provider=provider, llm=llm, **kwargs,
    )


async def test_read_tool_result_is_summarized():
    db = FakeSession()
    provider = _provider(
        ["GMAIL_FETCH_EMAILS"],
        results={"GMAIL_FETCH_EMAILS": ToolResult(
            ok=True, data={"messages": [{"from": "Ada", "subject": "Budget"}]}
        )},
    )
    llm = RecordingLLM([
        _calls(("GMAIL_FETCH_EMAILS", {"max_results": 5})),
        _text("You have one email from Ada about the budget."),
    ])

    outcome = await _run(db, "Summarize my latest emails", provider, llm)

    assert outcome.answer == "You have one email from Ada about the budget."
    assert outcome.pending_action is None
    assert outcome.executed_tools == ["GMAIL_FETCH_EMAILS"]
    assert provider.executed == [("GMAIL_FETCH_EMAILS", {"max_results": 5})]
    logs = db.of(ActionLog)
    assert len(logs) == 1
    assert logs[0].outcome == "ok" and logs[0].source == "chat"
    # The tool result reached the model as JSON, answering the right call id
    (tool_msg,) = _tool_messages(llm.call_log[1])
    assert tool_msg.tool_call_id == "c0"
    assert json.loads(tool_msg.content) == {"messages": [{"from": "Ada", "subject": "Budget"}]}
    # The assistant turn with the tool call precedes the tool message
    assistant = [m for m in llm.call_log[1] if m.role == "assistant"]
    assert assistant[-1].tool_calls[0].name == "GMAIL_FETCH_EMAILS"
    # Tools offered: search_memory, Echo's own tools (routines, to-dos, Saved), the
    # connected toolkit's tools
    names = [t["function"]["name"] for t in llm.tools_log[0]]
    assert names == [
        "search_memory", "ECHO_CREATE_ROUTINE", "ECHO_LIST_ROUTINES", "ECHO_DELETE_ROUTINE",
        "ECHO_CREATE_TASK", "ECHO_SAVE_ITEM", "ECHO_UPDATE_ITEM", "ECHO_FIND_ITEMS",
        "ECHO_SUM_ITEMS", "ECHO_REMOVE_ITEM", "GMAIL_FETCH_EMAILS",
    ]


async def test_system_prompt_and_history_are_sent():
    db = FakeSession()
    provider = _provider([])
    llm = RecordingLLM([_text("ok")])
    history = [
        {"role": "user", "content": "Who is Ada?"},
        {"role": "assistant", "content": "A colleague."},
    ]

    await _run(db, "Email her", provider, llm, history=history)

    messages = llm.call_log[0]
    assert [m.role for m in messages] == ["system", "user", "assistant", "user"]
    assert messages[1].content == "Who is Ada?" and messages[3].content == "Email her"
    system = messages[0].content
    assert settings.user_timezone in system
    assert "same language" in system
    assert "1 hour" in system
    from datetime import datetime

    from app.core.timezone import user_zone

    assert datetime.now(user_zone()).date().isoformat() in system


async def test_confirm_tool_creates_pending_action_and_is_not_executed():
    db = FakeSession()
    provider = _provider(["GMAIL_SEND_EMAIL"])
    args = {"to": "ada@x.it", "subject": "Hi", "body": "hello"}
    llm = RecordingLLM([_calls(("GMAIL_SEND_EMAIL", args))])

    outcome = await _run(db, "Send an email to Ada saying hello", provider, llm)

    assert provider.executed == []
    assert len(llm.call_log) == 1  # the loop stopped
    pending = outcome.pending_action
    assert pending is not None
    assert pending.tool == "GMAIL_SEND_EMAIL" and pending.arguments == args
    assert pending.summary == "Send email to ada@x.it: Hi\nhello"
    assert pending.session_id == SESSION and pending.source == "chat"
    assert pending.status == "pending" and pending.user_id == USER
    assert outcome.answer == f"{pending.summary}\nConfirm in the app to proceed."
    assert outcome.executed_tools == []
    assert db.of(ActionLog) == []


async def test_pending_action_reply_is_localized():
    db = FakeSession()
    provider = _provider(["GMAIL_SEND_EMAIL"])
    llm = RecordingLLM([_calls(("GMAIL_SEND_EMAIL", {"to": "ada@x.it"}))])

    outcome = await _run(db, "Manda una mail ad Ada per dirle che arrivo", provider, llm)

    assert outcome.answer.endswith("Conferma nell'app per procedere.")


async def test_second_confirm_call_in_the_same_turn_is_dropped():
    db = FakeSession()
    provider = _provider(["GMAIL_SEND_EMAIL", "GMAIL_FETCH_EMAILS"])
    llm = RecordingLLM([_calls(
        ("GMAIL_SEND_EMAIL", {"to": "ada@x.it", "body": "hi"}),
        ("GMAIL_SEND_EMAIL", {"to": "marco@x.it", "body": "hi"}),
        ("GMAIL_FETCH_EMAILS", {}),
    )])

    outcome = await _run(db, "Send this to Ada and Marco", provider, llm)

    assert provider.executed == []  # neither the second send nor the read ran
    pendings = db.of(PendingAction)
    assert len(pendings) == 1
    assert pendings[0].arguments["to"] == "ada@x.it"
    assert outcome.pending_action is pendings[0]
    assert len(llm.call_log) == 1
    assert db.of(ActionLog) == []


async def test_tool_result_is_truncated_for_the_model():
    db = FakeSession()
    provider = _provider(
        ["GMAIL_FETCH_EMAILS"],
        results={"GMAIL_FETCH_EMAILS": ToolResult(ok=True, data="x" * 50_000)},
    )
    llm = RecordingLLM([_calls(("GMAIL_FETCH_EMAILS", {})), _text("Lots of mail.")])

    await _run(db, "Summarize my emails", provider, llm)

    (tool_msg,) = _tool_messages(llm.call_log[1])
    assert MAX_TOOL_RESULT_CHARS == 12_000
    assert len(tool_msg.content) <= 12_000
    assert tool_msg.content.endswith("[truncated]")
    assert tool_msg.content.startswith('"xxx')


async def test_disconnected_account_gives_an_explicit_answer():
    db = FakeSession()
    provider = _provider(
        ["GMAIL_FETCH_EMAILS"],
        results={"GMAIL_FETCH_EMAILS": AccountNotConnectedError("gmail")},
    )
    llm = RecordingLLM([_calls(("GMAIL_FETCH_EMAILS", {})), _text("")])

    outcome = await _run(db, "Summarize my latest emails", provider, llm)

    assert "Gmail" in outcome.answer
    assert "isn't connected" in outcome.answer
    (log,) = db.of(ActionLog)
    assert log.outcome == "error" and log.toolkit == "gmail"
    (tool_msg,) = _tool_messages(llm.call_log[1])
    assert "error" in json.loads(tool_msg.content)


async def test_disconnected_account_answer_in_italian():
    db = FakeSession()
    provider = _provider(
        ["GMAIL_FETCH_EMAILS"],
        results={"GMAIL_FETCH_EMAILS": AccountNotConnectedError("gmail")},
    )
    llm = RecordingLLM([_calls(("GMAIL_FETCH_EMAILS", {})), _text("")])

    outcome = await _run(db, "Riassumimi le ultime mail di oggi", provider, llm)

    assert "Gmail non è collegato" in outcome.answer


@pytest.mark.parametrize("failure", [
    ActionProviderError("Composio request timed out"),
    ToolResult(ok=False, error="Composio request timed out"),
])
async def test_provider_error_is_reported_not_claimed(failure):
    db = FakeSession()
    provider = _provider(["GMAIL_FETCH_EMAILS"], results={"GMAIL_FETCH_EMAILS": failure})
    llm = RecordingLLM([_calls(("GMAIL_FETCH_EMAILS", {})), _text("")])

    outcome = await _run(db, "Summarize my latest emails", provider, llm)

    assert "Gmail" in outcome.answer
    assert "couldn't reach" in outcome.answer
    (log,) = db.of(ActionLog)
    assert log.outcome == "error"
    assert log.error == "Composio request timed out"
    (tool_msg,) = _tool_messages(llm.call_log[1])
    assert json.loads(tool_msg.content) == {"error": "Composio request timed out"}


async def test_success_claim_after_a_failed_tool_is_replaced():
    db = FakeSession()
    provider = _provider(
        ["GMAIL_FETCH_EMAILS"],
        results={"GMAIL_FETCH_EMAILS": ActionProviderError("boom")},
    )
    llm = RecordingLLM([_calls(("GMAIL_FETCH_EMAILS", {})), _text("Done!")])

    outcome = await _run(db, "Summarize my latest emails", provider, llm)

    assert "Done!" not in outcome.answer
    assert "couldn't reach Gmail" in outcome.answer


async def test_failed_create_after_successful_read_in_same_toolkit_is_not_claimed():
    db = FakeSession()
    provider = _provider(
        ["GMAIL_FETCH_EMAILS", "GMAIL_CREATE_EMAIL_DRAFT"],
        results={
            "GMAIL_FETCH_EMAILS": ToolResult(ok=True, data={"messages": []}),
            "GMAIL_CREATE_EMAIL_DRAFT": ToolResult(ok=False, error="quota exceeded"),
        },
    )
    llm = RecordingLLM([
        _calls(("GMAIL_FETCH_EMAILS", {})),
        _calls(("GMAIL_CREATE_EMAIL_DRAFT", {"subject": "Re: budget", "body": "hi"})),
        _text("Draft created."),
    ])

    outcome = await _run(db, "Read Ada's last email and draft a reply", provider, llm)

    assert "Draft created." not in outcome.answer
    assert "couldn't reach Gmail" in outcome.answer
    assert [log.outcome for log in db.of(ActionLog)] == ["ok", "error"]


async def test_retried_tool_that_succeeds_is_not_reported_as_failed():
    class FlakyProvider(FakeActionProvider):
        async def execute(self, user_id, tool, arguments):
            self.executed.append((tool, arguments))
            if len(self.executed) == 1:
                raise ActionProviderError("timeout")
            return ToolResult(ok=True, data={"id": "d1"})

    db = FakeSession()
    provider = FlakyProvider(
        connected={"gmail"},
        tools={"GMAIL_CREATE_EMAIL_DRAFT": _schema("GMAIL_CREATE_EMAIL_DRAFT")},
    )
    llm = RecordingLLM([
        _calls(("GMAIL_CREATE_EMAIL_DRAFT", {"subject": "Hi Ada"})),
        _calls(("GMAIL_CREATE_EMAIL_DRAFT", {"subject": "Hi Ada"})),
        _text("Draft created."),
    ])

    outcome = await _run(db, "Draft an email to Ada", provider, llm)

    assert outcome.answer == "Draft created."
    assert [log.outcome for log in db.of(ActionLog)] == ["error", "ok"]


async def test_model_explanation_naming_the_toolkit_is_kept():
    db = FakeSession()
    provider = _provider(
        ["GMAIL_FETCH_EMAILS"],
        results={"GMAIL_FETCH_EMAILS": AccountNotConnectedError("gmail")},
    )
    llm = RecordingLLM([
        _calls(("GMAIL_FETCH_EMAILS", {})),
        _text("Gmail is not connected: connect it in the app."),
    ])

    outcome = await _run(db, "Summarize my latest emails", provider, llm)

    assert outcome.answer == "Gmail is not connected: connect it in the app."


async def test_unreachable_provider_when_listing_toolkits():
    class DownProvider(FakeActionProvider):
        async def connected_toolkits(self, user_id):
            raise ActionProviderError("Composio request timed out")

    db = FakeSession()
    llm = RecordingLLM([])

    outcome = await _run(db, "Summarize my latest emails", DownProvider(), llm)

    assert "couldn't reach" in outcome.answer
    assert llm.call_log == []


async def test_tool_not_offered_is_not_executed():
    db = FakeSession()
    provider = _provider(["GMAIL_FETCH_EMAILS"], connected={"gmail", "slack"})
    llm = RecordingLLM([
        _calls(("SLACK_SEND_MESSAGE", {"channel": "x", "text": "hi"})),
        _text("I can't do that."),
    ])

    outcome = await _run(db, "Post hi on Slack", provider, llm)

    assert provider.executed == []
    assert db.of(PendingAction) == [] and db.of(ActionLog) == []
    assert outcome.pending_action is None
    (tool_msg,) = _tool_messages(llm.call_log[1])
    assert "error" in json.loads(tool_msg.content)


async def test_search_memory_tool_uses_memory_retrieval(monkeypatch):
    seen = []

    async def fake_retrieve(db, user_id, question, **kwargs):
        seen.append((db, user_id, question))
        return MemoryContext(context="Ada said the meeting moved to Friday.", sources=[])

    monkeypatch.setattr(agent_module, "retrieve_memory_context", fake_retrieve)
    db = FakeSession()
    provider = _provider(["GMAIL_FETCH_EMAILS"])
    llm = RecordingLLM([
        _calls(("search_memory", {"query": "meeting with Ada"})),
        _text("The meeting is on Friday."),
    ])

    outcome = await _run(db, "When is the meeting with Ada?", provider, llm)

    assert seen == [(db, USER, "meeting with Ada")]
    (tool_msg,) = _tool_messages(llm.call_log[1])
    assert "Ada said the meeting moved to Friday." in tool_msg.content
    assert outcome.answer == "The meeting is on Friday."
    assert outcome.executed_tools == []
    assert provider.executed == [] and db.of(ActionLog) == []
    assert SEARCH_MEMORY_TOOL["function"]["name"] == "search_memory"
    assert "query" in SEARCH_MEMORY_TOOL["function"]["parameters"]["properties"]


async def test_search_memory_with_no_results_says_so(monkeypatch):
    async def fake_retrieve(db, user_id, question, **kwargs):
        return MemoryContext(context="", sources=[])

    monkeypatch.setattr(agent_module, "retrieve_memory_context", fake_retrieve)
    db = FakeSession()
    llm = RecordingLLM([_calls(("search_memory", {"query": "x"})), _text("Nothing.")])

    await _run(db, "What did Ada say?", _provider([]), llm)

    (tool_msg,) = _tool_messages(llm.call_log[1])
    assert "nothing found" in tool_msg.content.lower()


async def test_step_limit_stops_the_loop():
    db = FakeSession()
    provider = _provider(["GMAIL_FETCH_EMAILS"])
    llm = RecordingLLM([_calls(("GMAIL_FETCH_EMAILS", {})) for _ in range(3)])

    outcome = await _run(db, "Summarize my emails", provider, llm, max_steps=3)

    assert len(llm.call_log) == 3
    assert len(provider.executed) == 3
    assert outcome.answer == agent_module.TEXTS["en"]["step_limit"]
    assert outcome.pending_action is None


async def test_given_connected_toolkits_are_not_listed_again():
    class NoListing(FakeActionProvider):
        async def list_toolkits(self, user_id, query=None):
            raise AssertionError("must not list toolkits")

        async def connected_toolkits(self, user_id):
            raise AssertionError("must not list connected accounts")

    db = FakeSession()
    provider = NoListing(connected={"gmail"}, tools={"GMAIL_FETCH_EMAILS": _schema(
        "GMAIL_FETCH_EMAILS"
    )})
    llm = RecordingLLM([_text("Nothing new.")])

    outcome = await _run(db, "Any new email?", provider, llm, connected_toolkits=["gmail"])

    assert outcome.answer == "Nothing new."
    names = [t["function"]["name"] for t in llm.tools_log[0]]
    assert "GMAIL_FETCH_EMAILS" in names


async def test_connected_toolkits_are_asked_once_when_not_given():
    class Counting(FakeActionProvider):
        calls = 0

        async def connected_toolkits(self, user_id):
            Counting.calls += 1
            return await super().connected_toolkits(user_id)

    provider = Counting(connected={"gmail"}, tools={"GMAIL_FETCH_EMAILS": _schema(
        "GMAIL_FETCH_EMAILS"
    )})
    llm = RecordingLLM([_text("ok")])
    await _run(FakeSession(), "Any new email?", provider, llm)
    assert Counting.calls == 1


async def test_create_event_with_attendees_needs_confirmation():
    db = FakeSession()
    provider = _provider(["GOOGLECALENDAR_CREATE_EVENT"], connected={"googlecalendar"})
    args = {"summary": "Sync", "attendees": ["ada@x.it"]}
    llm = RecordingLLM([_calls(("GOOGLECALENDAR_CREATE_EVENT", args))])

    outcome = await _run(db, "Set up a sync with Ada tomorrow", provider, llm)

    assert provider.executed == []
    assert outcome.pending_action is not None
    assert outcome.pending_action.tool == "GOOGLECALENDAR_CREATE_EVENT"


async def test_create_event_without_attendees_runs_immediately():
    db = FakeSession()
    provider = _provider(["GOOGLECALENDAR_CREATE_EVENT"], connected={"googlecalendar"})
    llm = RecordingLLM([
        _calls(("GOOGLECALENDAR_CREATE_EVENT", {"summary": "Dentist"})),
        _text("Added."),
    ])

    outcome = await _run(db, "Add the dentist tomorrow at 10", provider, llm)

    assert provider.executed == [("GOOGLECALENDAR_CREATE_EVENT", {"summary": "Dentist"})]
    assert outcome.pending_action is None and outcome.answer == "Added."


async def test_timeout_during_execution_is_reported_as_unknown():
    from app.actions.provider import ActionOutcomeUnknown

    db = FakeSession()
    provider = _provider(
        ["GOOGLECALENDAR_CREATE_EVENT"],
        connected={"googlecalendar"},
        results={"GOOGLECALENDAR_CREATE_EVENT": ActionOutcomeUnknown("timed out")},
    )
    llm = RecordingLLM([
        _calls(("GOOGLECALENDAR_CREATE_EVENT", {"summary": "Dentist"})),
        _text("Google Calendar did not answer in time."),
    ])

    outcome = await _run(db, "Add the dentist tomorrow at 10", provider, llm)

    (log,) = db.of(ActionLog)
    assert log.outcome == "unknown"
    (tool_msg,) = _tool_messages(llm.call_log[1])
    assert json.loads(tool_msg.content)["outcome"] == "unknown"
    assert outcome.answer.startswith("Google Calendar did not answer in time.")
    assert outcome.answer.endswith(
        "I couldn't confirm whether it went through — check Google Calendar before trying again."
    )
    assert "nothing was done" not in outcome.answer


async def test_unknown_outcome_note_in_italian_even_without_a_model_answer():
    from app.actions.provider import ActionOutcomeUnknown

    db = FakeSession()
    provider = _provider(
        ["TODOIST_CREATE_TASK"],
        connected={"todoist"},
        results={"TODOIST_CREATE_TASK": ActionOutcomeUnknown("timed out")},
    )
    llm = RecordingLLM([_calls(("TODOIST_CREATE_TASK", {"content": "latte"})), _text("")])

    outcome = await _run(db, "Crea un task per comprare il latte", provider, llm)

    assert outcome.answer == (
        "Non sono riuscito a verificare se è andata a buon fine: "
        "controlla Todoist prima di riprovare."
    )


# --- G4: the "check {App}" note after an unknown outcome is never dropped ----------------


async def test_unknown_outcome_note_survives_a_successful_retry_of_the_same_tool():
    from app.actions.provider import ActionOutcomeUnknown

    class TimesOutOnce(FakeActionProvider):
        async def execute(self, user_id, tool, arguments):
            self.executed.append((tool, arguments))
            if len(self.executed) == 1:
                raise ActionOutcomeUnknown("timed out")
            return ToolResult(ok=True, data={"id": "evt-2"})

    db = FakeSession()
    provider = TimesOutOnce(
        connected={"googlecalendar"},
        tools={"GOOGLECALENDAR_CREATE_EVENT": _schema("GOOGLECALENDAR_CREATE_EVENT")},
    )
    llm = RecordingLLM([
        _calls(("GOOGLECALENDAR_CREATE_EVENT", {"summary": "Dentist"})),
        _calls(("GOOGLECALENDAR_CREATE_EVENT", {"summary": "Dentist"})),
        _text("Added the dentist."),
    ])

    outcome = await _run(db, "Add the dentist tomorrow at 10", provider, llm)

    assert [log.outcome for log in db.of(ActionLog)] == ["unknown", "ok"]
    # The first call may also have gone through (a duplicate event): the note stays
    assert outcome.answer == (
        "Added the dentist.\n"
        "I couldn't confirm whether it went through — check Google Calendar before trying again."
    )


async def test_unknown_tool_result_from_the_provider_gets_the_check_note():
    """R29: an unknown outcome returned as a ToolResult (non-dict Composio response)."""
    db = FakeSession()
    unknown = ToolResult(ok=False, unknown=True, error="unexpected response from Composio")
    provider = _provider(
        ["TODOIST_CREATE_TASK"], connected={"todoist"}, results={"TODOIST_CREATE_TASK": unknown}
    )
    llm = RecordingLLM([_calls(("TODOIST_CREATE_TASK", {"content": "milk"})), _text("")])

    outcome = await _run(db, "Add a task to buy milk", provider, llm)

    assert [log.outcome for log in db.of(ActionLog)] == ["unknown"]
    assert outcome.answer == (
        "I couldn't confirm whether it went through — check Todoist before trying again."
    )
