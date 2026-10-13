import pytest

from app.actions.policy import ToolTier, classify_tool, toolkit_of
from app.actions.provider import AccountNotConnectedError, ToolResult
from tests.fakes.action_provider import FakeActionProvider


@pytest.mark.parametrize(
    "slug,tier",
    [
        ("GMAIL_SEND_EMAIL", ToolTier.CONFIRM),
        ("GOOGLECALENDAR_DELETE_EVENT", ToolTier.CONFIRM),
        ("GOOGLECALENDAR_UPDATE_EVENT", ToolTier.CONFIRM),
        ("SLACK_SEND_MESSAGE", ToolTier.CONFIRM),
        ("GMAIL_FETCH_EMAILS", ToolTier.READ),
        ("GOOGLECALENDAR_EVENTS_LIST", ToolTier.READ),
        ("SLACK_FETCH_CONVERSATION_HISTORY", ToolTier.READ),
        ("GMAIL_CREATE_EMAIL_DRAFT", ToolTier.CREATE),
        ("GOOGLECALENDAR_CREATE_EVENT", ToolTier.CREATE),
        ("TODOIST_CREATE_TASK", ToolTier.CREATE),
        ("SOMEAPP_DO_MAGIC", ToolTier.CONFIRM),
        ("GMAIL_FETCH_AND_DELETE", ToolTier.CONFIRM),
        ("SHEETS_BUDGET_SUMMARY", ToolTier.CONFIRM),
    ],
)
def test_classify_tool(slug, tier):
    assert classify_tool(slug) == tier


def test_toolkit_of():
    assert toolkit_of("GOOGLECALENDAR_CREATE_EVENT") == "googlecalendar"


def _schema(name):
    return {"type": "function", "function": {"name": name, "parameters": {}}}


async def test_fake_tools_for_filters_connected():
    fake = FakeActionProvider(
        connected={"gmail"},
        tools={"GMAIL_FETCH_EMAILS": _schema("GMAIL_FETCH_EMAILS"),
               "SLACK_SEND_MESSAGE": _schema("SLACK_SEND_MESSAGE")},
    )
    out = await fake.tools_for("u", ["gmail", "slack"])
    assert [t["function"]["name"] for t in out] == ["GMAIL_FETCH_EMAILS"]


async def test_fake_execute():
    fake = FakeActionProvider(
        connected={"gmail"}, results={"GMAIL_FETCH_EMAILS": ToolResult(ok=True, data=[1])}
    )
    assert (await fake.execute("u", "GMAIL_FETCH_EMAILS", {"a": 1})).data == [1]
    assert fake.executed == [("GMAIL_FETCH_EMAILS", {"a": 1})]
    with pytest.raises(AccountNotConnectedError) as exc:
        await fake.execute("u", "SLACK_SEND_MESSAGE", {})
    assert exc.value.toolkit == "slack"
