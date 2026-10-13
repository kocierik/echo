"""Unit tests: chat finds calendar events by title/date and skips needless LLM calls."""

import uuid

import pytest

from app.services import calendar_service, chat_actions
from app.services.calendar_service import match_events, rfc3339_day_range

USER_ID = uuid.uuid4()

EVENTS = [
    {"id": "e1", "summary": "Dentista", "start": "2026-10-14T15:00:00+02:00"},
    {"id": "e2", "summary": "Pranzo con Ada", "start": "2026-10-15T13:00:00+02:00"},
    {"id": "e3", "summary": "Pranzo con Marco", "start": "2026-10-16T13:00:00+02:00"},
    {"id": "e4", "summary": "Palestra", "start": "2026-10-16"},
]


# --- Title matching ---


def test_exact_title_ranks_first():
    assert [e["id"] for e in match_events(EVENTS, "dentista")] == ["e1"]


def test_partial_title_matches_every_candidate():
    assert {e["id"] for e in match_events(EVENTS, "pranzo")} == {"e2", "e3"}


def test_typo_still_matches():
    assert [e["id"] for e in match_events(EVENTS, "dentsita")] == ["e1"]


def test_unrelated_or_empty_title_matches_nothing():
    assert match_events(EVENTS, "riunione budget") == []
    assert match_events(EVENTS, "  ") == []


# --- Local day bounds (Europe/Rome) ---


def test_local_day_bounds_use_the_user_timezone():
    assert rfc3339_day_range("2026-10-13", "2026-10-13") == (
        "2026-10-13T00:00:00+02:00",
        "2026-10-14T00:00:00+02:00",
    )


def test_local_day_bounds_follow_the_dst_change():
    # 25 Oct 2026: Italy goes back from CEST (+02) to CET (+01)
    assert rfc3339_day_range("2026-10-25", "2026-10-26") == (
        "2026-10-25T00:00:00+02:00",
        "2026-10-27T00:00:00+01:00",
    )


@pytest.mark.asyncio
async def test_list_events_sends_local_day_bounds(monkeypatch):
    captured = {}

    async def fake_token(_db, _user_id):
        return "token"

    class _Response:
        status_code = 200

        def json(self):
            return {"items": []}

    class _Client:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_exc):
            return False

        async def get(self, url, headers=None, params=None):
            captured.update(params)
            return _Response()

    monkeypatch.setattr(calendar_service, "get_calendar_token", fake_token)
    monkeypatch.setattr(calendar_service.httpx, "AsyncClient", _Client)

    await calendar_service.list_events(None, USER_ID, date_from="2026-10-13")

    assert captured["timeMin"] == "2026-10-13T00:00:00+02:00"
    assert captured["timeMax"] == "2026-10-14T00:00:00+02:00"


# --- Resolving the event an update/delete refers to ---


def _patch_find(monkeypatch, matches, calls=None):
    async def fake_find(_db, _user_id, summary, day=None):
        if calls is not None:
            calls.append((summary, day))
        return matches

    monkeypatch.setattr(chat_actions, "find_events", fake_find)


@pytest.mark.asyncio
async def test_single_match_is_resolved(monkeypatch):
    calls = []
    _patch_find(monkeypatch, [EVENTS[0]], calls)

    event, reply = await chat_actions._resolve_event(
        None, USER_ID, {"target": {"summary": "Dentista", "date": "2026-10-14"}}, "update"
    )

    assert event == EVENTS[0]
    assert reply is None
    assert calls == [("Dentista", "2026-10-14")]


@pytest.mark.asyncio
async def test_several_matches_ask_which_one(monkeypatch):
    _patch_find(monkeypatch, [EVENTS[1], EVENTS[2]])

    event, reply = await chat_actions._resolve_event(
        None, USER_ID, {"target": {"summary": "pranzo"}}, "delete", "it"
    )

    assert event is None
    assert "Pranzo con Ada" in reply and "Pranzo con Marco" in reply
    assert "Quale intendi?" in reply


@pytest.mark.asyncio
async def test_no_match_and_disconnected_calendar_are_explained(monkeypatch):
    _patch_find(monkeypatch, [])
    _, reply = await chat_actions._resolve_event(
        None, USER_ID, {"target": {"summary": "Yoga"}}, "delete", "it"
    )
    assert "Non ho trovato \"Yoga\"" in reply

    _patch_find(monkeypatch, None)
    _, reply = await chat_actions._resolve_event(
        None, USER_ID, {"target": {"summary": "Yoga"}}, "delete", "it"
    )
    assert "non è connesso" in reply


@pytest.mark.asyncio
async def test_missing_target_asks_for_the_event():
    event, reply = await chat_actions._resolve_event(None, USER_ID, {}, "update", "it")

    assert event is None
    assert reply.startswith("Quale evento vuoi modificare?")

    _, reply = await chat_actions._resolve_event(None, USER_ID, {}, "delete", "en")
    assert reply.startswith("Which event do you want to delete?")


@pytest.mark.asyncio
async def test_explicit_event_id_is_used_directly(monkeypatch):
    _patch_find(monkeypatch, AssertionError("must not search"))

    event, _ = await chat_actions._resolve_event(None, USER_ID, {"event_id": "abc"}, "delete")

    assert event == {"id": "abc"}


@pytest.mark.asyncio
async def test_delete_by_name_deletes_the_matched_event(monkeypatch):
    _patch_find(monkeypatch, [EVENTS[0]])
    deleted = []

    async def fake_delete(_db, _user_id, event_id):
        deleted.append(event_id)
        return True

    monkeypatch.setattr(chat_actions, "delete_event", fake_delete)

    reply = await chat_actions._execute_action(
        None, USER_ID, "calendar_delete", {"target": {"summary": "dentista"}}, language="it"
    )

    assert deleted == ["e1"]
    assert reply == "✅ Evento **Dentista** eliminato."


@pytest.mark.asyncio
async def test_update_by_name_passes_only_the_changes(monkeypatch):
    _patch_find(monkeypatch, [EVENTS[0]])
    updates = []

    async def fake_update(_db, _user_id, **kwargs):
        updates.append(kwargs)
        return {"summary": "Dentista"}

    monkeypatch.setattr(chat_actions, "update_event", fake_update)

    await chat_actions._execute_action(
        None,
        USER_ID,
        "calendar_update",
        {"target": {"summary": "Dentista"}, "time": "18:00"},
    )

    assert updates == [{
        "event_id": "e1",
        "summary": None,
        "date": None,
        "time": "18:00",
        "location": None,
        "duration_minutes": None,
    }]


# --- Skipping the intent classifier ---


@pytest.mark.parametrize(
    "question",
    [
        "Crea un evento domani alle 15",
        "Che impegni ho venerdì?",
        "sposta il dentista alle 18",
        "Cancella la palestra",
        "Add a meeting with Ada",
        "fissami una call con Marco",
    ],
)
def test_calendar_requests_reach_the_classifier(question):
    assert chat_actions.might_be_calendar_action(question, [])


@pytest.mark.parametrize(
    "question",
    [
        "Cosa mi ha detto Marco ieri?",
        "Di cosa abbiamo parlato a pranzo?",
        "Quali idee ho avuto questa settimana?",
    ],
)
def test_memory_questions_skip_the_classifier(question):
    assert not chat_actions.might_be_calendar_action(question, [])


def test_reply_to_a_calendar_question_reaches_the_classifier():
    history = [
        {"role": "user", "content": "cancella il pranzo"},
        {"role": "assistant", "content": "Ho trovato più eventi:\n... Quale intendi? ..."},
    ]

    assert chat_actions.might_be_calendar_action("quello con Ada", history)


@pytest.mark.asyncio
async def test_memory_question_makes_no_llm_call(monkeypatch):
    def fail():
        raise AssertionError("intent classifier must not be called")

    monkeypatch.setattr(chat_actions, "get_llm_query_service", fail)

    assert await chat_actions.detect_and_execute_action(
        None, USER_ID, "Cosa mi ha detto Marco ieri?", []
    ) is None
