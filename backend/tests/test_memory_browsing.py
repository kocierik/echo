"""Conversation list/detail fields, memory search and open tasks: what the Memories and
Tasks screens of the app read."""

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from tests.factories import make_conversation, make_entity

NOW = datetime.now(timezone.utc)


@pytest.mark.asyncio
async def test_list_has_emoji_duration_people_tasks_and_open_state(
    client, auth_headers, db_session: AsyncSession
):
    # "Open" is relative to the request: the module's NOW is minutes old in a full run
    now = datetime.now(timezone.utc)
    closed, _ = await make_conversation(db_session, started_at=now - timedelta(hours=3), minutes=12)
    db_session.add_all(
        [
            make_entity(closed, "person", "Ada"),
            make_entity(closed, "person", "Marco"),
            make_entity(closed, "person", "Ada"),  # listed once
            make_entity(closed, "person", "Bea"),
            make_entity(closed, "person", "Carlo"),  # only three are listed
            make_entity(closed, "task", "Chiamare Ada"),
            make_entity(closed, "idea", "Atlas"),
        ]
    )
    live, _ = await make_conversation(
        db_session, started_at=now - timedelta(seconds=30), minutes=0, title=None, emoji=None
    )
    await db_session.commit()

    response = await client.get("/api/conversations", headers=auth_headers)

    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 2
    first, second = body["conversations"]
    assert first["id"] == str(live.id)
    assert first["is_open"] is True
    assert first["emoji"] is None
    assert second["id"] == str(closed.id)
    assert second["is_open"] is False
    assert second["emoji"] == "🍝"
    assert second["duration_s"] == 12 * 60
    assert second["people"] == ["Ada", "Marco", "Bea"]
    assert second["task_count"] == 1
    assert second["segment_count"] == 1


@pytest.mark.asyncio
async def test_list_filters_by_overlapping_period(client, auth_headers, db_session: AsyncSession):
    day = datetime(2026, 10, 10, tzinfo=timezone.utc)
    await make_conversation(db_session, started_at=day - timedelta(days=1), title="Before")
    across_midnight, _ = await make_conversation(
        db_session, started_at=day - timedelta(minutes=5), minutes=20, title="Across midnight"
    )
    inside, _ = await make_conversation(
        db_session, started_at=day + timedelta(hours=9), title="Inside"
    )
    await make_conversation(db_session, started_at=day + timedelta(days=1, hours=1), title="After")
    await db_session.commit()

    response = await client.get(
        "/api/conversations",
        headers=auth_headers,
        params={
            "date_from": day.isoformat(),
            "date_to": (day + timedelta(days=1)).isoformat(),
        },
    )

    assert [c["title"] for c in response.json()["conversations"]] == [
        "Inside",
        "Across midnight",
    ]
    assert response.json()["total"] == 2


@pytest.mark.asyncio
async def test_list_rejects_an_unbounded_limit(client, auth_headers):
    response = await client.get("/api/conversations?limit=1000", headers=auth_headers)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_detail_lists_pending_segments_speakers_and_entity_sources(
    client, auth_headers, db_session: AsyncSession
):
    conversation, (said, pending) = await make_conversation(
        db_session,
        started_at=NOW - timedelta(hours=1),
        texts=("[Tu] Devo chiamare Ada domani.", None),
    )
    db_session.add(
        make_entity(
            conversation,
            "task",
            "Chiamare Ada",
            source=said,
            metadata={"due_date": "2026-10-15"},
        )
    )
    await db_session.commit()

    response = await client.get(f"/api/conversations/{conversation.id}", headers=auth_headers)

    assert response.status_code == 200
    body = response.json()
    assert body["emoji"] == "🍝"
    assert body["duration_s"] == 600
    assert body["is_open"] is False
    first, second = body["transcriptions"]
    assert first["text"] == "[Tu] Devo chiamare Ada domani."
    assert first["speaker_label"] == "self"
    assert first["status"] == "completed"
    assert first["segment_id"]
    assert second["text"] is None
    assert second["status"] == "pending"
    (task,) = body["entities"]
    assert task["source_text"] == "[Tu] Devo chiamare Ada domani."
    assert task["metadata_"] == {"due_date": "2026-10-15"}


@pytest.mark.asyncio
async def test_search_finds_titles_summaries_transcripts_and_entities(
    client, auth_headers, db_session: AsyncSession
):
    by_title, _ = await make_conversation(
        db_session, started_at=NOW - timedelta(days=3), title="Atlas kickoff", summary="Plan."
    )
    by_transcript, (said,) = await make_conversation(
        db_session,
        started_at=NOW - timedelta(days=1),
        title="Lunch",
        summary="Food.",
        texts=("[Tu] Il progetto atlas parte lunedì.",),
    )
    await make_conversation(
        db_session, started_at=NOW, title="Gym", summary="Legs.", texts=("Squat.",)
    )
    db_session.add(make_entity(by_transcript, "idea", "Atlas dashboard", source=said))
    db_session.add(make_entity(by_transcript, "note", "Budget", content="Atlas costs 10k"))
    await db_session.commit()

    response = await client.get("/api/search", headers=auth_headers, params={"q": "ATLAS"})

    assert response.status_code == 200
    body = response.json()
    assert [c["id"] for c in body["conversations"]] == [str(by_transcript.id), str(by_title.id)]
    names = {e["name"] for e in body["entities"]}
    assert names == {"Atlas dashboard", "Budget"}
    idea = next(e for e in body["entities"] if e["name"] == "Atlas dashboard")
    assert idea["source_text"] == "[Tu] Il progetto atlas parte lunedì."
    assert idea["conversation_id"] == str(by_transcript.id)


@pytest.mark.asyncio
async def test_search_matches_wildcards_literally_and_needs_two_characters(
    client, auth_headers, db_session: AsyncSession
):
    await make_conversation(db_session, started_at=NOW, title="Sconto del 50%", texts=("ok",))
    await make_conversation(db_session, started_at=NOW, title="Sconto del 500", texts=("ok",))
    await db_session.commit()

    literal = await client.get("/api/search", headers=auth_headers, params={"q": "50%"})
    too_short = await client.get("/api/search", headers=auth_headers, params={"q": "a"})

    assert [c["title"] for c in literal.json()["conversations"]] == ["Sconto del 50%"]
    assert too_short.status_code == 422


@pytest.mark.asyncio
async def test_search_never_returns_another_users_memory(
    client, auth_headers, db_session: AsyncSession
):
    stranger = uuid.uuid4()
    other, (said,) = await make_conversation(
        db_session, started_at=NOW, title="Atlas secret", user_id=stranger
    )
    db_session.add(make_entity(other, "note", "Atlas secret note", source=said))
    await db_session.commit()

    response = await client.get("/api/search", headers=auth_headers, params={"q": "atlas"})

    assert response.json() == {"conversations": [], "entities": []}


@pytest.mark.asyncio
async def test_open_tasks_include_tasks_without_a_done_flag_and_their_source(
    client, auth_headers, db_session: AsyncSession
):
    conversation, (said,) = await make_conversation(
        db_session, started_at=NOW, texts=("[Tu] Devo comprare il latte.",)
    )
    db_session.add_all(
        [
            make_entity(conversation, "task", "Comprare il latte", source=said),
            make_entity(conversation, "task", "Pagare la bolletta", metadata={"done": False}),
            make_entity(conversation, "task", "Prenotare il volo", metadata={"done": True}),
        ]
    )
    await db_session.commit()

    open_tasks = await client.get("/api/entities/tasks?done=false", headers=auth_headers)
    done_tasks = await client.get("/api/entities/tasks?done=true", headers=auth_headers)

    names = {t["name"]: t for t in open_tasks.json()["entities"]}
    assert set(names) == {"Comprare il latte", "Pagare la bolletta"}
    assert names["Comprare il latte"]["source_text"] == "[Tu] Devo comprare il latte."
    assert names["Comprare il latte"]["conversation_id"] == str(conversation.id)
    assert [t["name"] for t in done_tasks.json()["entities"]] == ["Prenotare il volo"]
