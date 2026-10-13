import pytest

from app.actions.policy import ToolTier, classify_call, classify_tool, toolkit_of
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


@pytest.mark.parametrize(
    "slug,arguments,tier",
    [
        ("GOOGLECALENDAR_CREATE_EVENT", {"summary": "Dentist"}, ToolTier.CREATE),
        ("GOOGLECALENDAR_CREATE_EVENT", {"summary": "Sync", "attendees": []}, ToolTier.CREATE),
        (
            "GOOGLECALENDAR_CREATE_EVENT",
            {"summary": "Sync", "attendees": ["ada@x.it"]},
            ToolTier.CONFIRM,
        ),
        ("GOOGLECALENDAR_CREATE_EVENT", {"send_updates": "all"}, ToolTier.CONFIRM),
        ("TODOIST_CREATE_TASK", {"content": "Milk"}, ToolTier.CREATE),
        ("TODOIST_CREATE_TASK", {"content": "Milk", "responsible_uid": "42"}, ToolTier.CONFIRM),
        ("TODOIST_CREATE_TASK", {"content": "Milk", "assignee_id": ""}, ToolTier.CREATE),
        ("GMAIL_CREATE_EMAIL_DRAFT", {"recipient_email": "ada@x.it"}, ToolTier.CONFIRM),
        ("GMAIL_CREATE_EMAIL_DRAFT", {"to": "ada@x.it"}, ToolTier.CONFIRM),
        ("GMAIL_CREATE_EMAIL_DRAFT", {"to_addresses": ["ada@x.it"]}, ToolTier.CONFIRM),
        ("GMAIL_CREATE_EMAIL_DRAFT", {"extra_cc": ["b@x.it"]}, ToolTier.CONFIRM),
        ("GMAIL_CREATE_EMAIL_DRAFT", {"bcc": "b@x.it"}, ToolTier.CONFIRM),
        ("NOTION_CREATE_NOTION_PAGE", {"title": "Ideas", "guest_ids": ["u"]}, ToolTier.CONFIRM),
        ("NOTION_CREATE_NOTION_PAGE", {"title": "Ideas", "invitees": "x"}, ToolTier.CONFIRM),
        # A key that only contains the letters of a keyword is not a recipient
        ("NOTION_CREATE_NOTION_PAGE", {"title": "Ideas", "account_id": "a"}, ToolTier.CREATE),
        ("NOTION_CREATE_NOTION_PAGE", {"title": "Ideas", "topic": "a"}, ToolTier.CREATE),
        # Non-create tiers are unchanged
        ("GMAIL_FETCH_EMAILS", {"to": "ada@x.it"}, ToolTier.READ),
        ("GMAIL_SEND_EMAIL", {}, ToolTier.CONFIRM),
    ],
)
def test_classify_call_escalates_creates_that_notify_people(slug, arguments, tier):
    assert classify_call(slug, arguments) == tier
