"""Entity mentions keep every conversation an entity came up in; People reads them."""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Entity, EntityMention
from app.services.conversation_deleter import delete_conversation
from app.services.conversation_reanalysis import reanalyse_conversation
from app.services.deduplication import merge_entities
from app.services.entity_mentions import record_mentions
from tests.conftest import TEST_USER_ID
from tests.factories import make_conversation, make_entity

NOW = datetime.now(timezone.utc)


class _NoStorage:
    """Conversations here have no audio on disk."""

    def exists(self, path):
        return False

    def rename(self, source, destination):
        raise AssertionError("no audio to move")

    def unlink(self, path):
        raise AssertionError("no audio to delete")


async def _marco_in_two_conversations(db: AsyncSession):
    """Marco mentioned last week and today: one entity, now pointing at today."""
    last_week, (old_line,) = await make_conversation(
        db,
        started_at=NOW - timedelta(days=7),
        title="Atlas kickoff",
        texts=("[Tu] Marco segue il design di Atlas.",),
    )
    today, (new_line,) = await make_conversation(
        db,
        started_at=NOW - timedelta(hours=2),
        title="Lunch",
        texts=("[Tu] Pranzo con Marco domani.",),
    )
    marco = make_entity(
        last_week, "person", "Marco", source=old_line, metadata={"role": "designer"}
    )
    db.add(marco)
    await db.flush()
    await record_mentions(db, [marco])
    # Consolidation of today's extraction moved the entity to today's conversation
    marco.conversation_id = today.id
    marco.source_transcription_id = new_line.id
    await record_mentions(db, [marco])
    await db.commit()
    return marco, last_week, today


@pytest.mark.asyncio
async def test_both_conversations_list_the_person(client, auth_headers, db_session: AsyncSession):
    await _marco_in_two_conversations(db_session)

    body = (await client.get("/api/conversations", headers=auth_headers)).json()

    assert [c["people"] for c in body["conversations"]] == [["Marco"], ["Marco"]]


@pytest.mark.asyncio
async def test_each_conversation_shows_its_own_sentence(
    client, auth_headers, db_session: AsyncSession
):
    _, last_week, today = await _marco_in_two_conversations(db_session)

    old = (await client.get(f"/api/conversations/{last_week.id}", headers=auth_headers)).json()
    new = (await client.get(f"/api/conversations/{today.id}", headers=auth_headers)).json()

    assert old["entities"][0]["source_text"] == "[Tu] Marco segue il design di Atlas."
    assert new["entities"][0]["source_text"] == "[Tu] Pranzo con Marco domani."


@pytest.mark.asyncio
async def test_deleting_one_conversation_keeps_a_person_mentioned_elsewhere(
    db_session: AsyncSession,
):
    marco, last_week, today = await _marco_in_two_conversations(db_session)
    marco_id, last_week_id, today_id = marco.id, last_week.id, today.id

    await delete_conversation(db_session, TEST_USER_ID, today_id, _NoStorage())
    db_session.expire_all()

    survivor = await db_session.get(Entity, marco_id)
    assert survivor is not None
    assert survivor.conversation_id == last_week_id
    mentions = (
        (
            await db_session.execute(
                select(EntityMention.conversation_id).where(EntityMention.entity_id == marco_id)
            )
        )
        .scalars()
        .all()
    )
    assert mentions == [last_week_id]


@pytest.mark.asyncio
async def test_deleting_the_only_conversation_deletes_its_entities(db_session: AsyncSession):
    conversation, (line,) = await make_conversation(db_session, started_at=NOW)
    ada = make_entity(conversation, "person", "Ada", source=line)
    db_session.add(ada)
    await db_session.flush()
    await record_mentions(db_session, [ada])
    await db_session.commit()
    ada_id, conversation_id = ada.id, conversation.id

    await delete_conversation(db_session, TEST_USER_ID, conversation_id, _NoStorage())
    db_session.expire_all()

    assert await db_session.get(Entity, ada_id) is None


@pytest.mark.asyncio
async def test_reanalysis_keeps_a_person_mentioned_elsewhere(db_session: AsyncSession):
    from tests.test_conversation_reanalysis import RecordingEmbeddings, RecordingLLM

    marco, last_week, today = await _marco_in_two_conversations(db_session)
    marco_id, last_week_id, today_id = marco.id, last_week.id, today.id

    await reanalyse_conversation(db_session, today_id, RecordingLLM(), RecordingEmbeddings())
    db_session.expire_all()

    survivor = await db_session.get(Entity, marco_id)
    assert survivor is not None
    assert survivor.conversation_id == last_week_id


@pytest.mark.asyncio
async def test_merging_duplicates_moves_their_mentions(db_session: AsyncSession):
    first, _ = await make_conversation(db_session, started_at=NOW - timedelta(days=2))
    second, _ = await make_conversation(db_session, started_at=NOW - timedelta(days=1))
    third, _ = await make_conversation(db_session, started_at=NOW)
    canonical = make_entity(first, "person", "Marco")
    duplicate = make_entity(second, "person", "Marco R.")
    db_session.add_all([canonical, duplicate])
    await db_session.flush()
    await record_mentions(db_session, [canonical, duplicate])
    duplicate.conversation_id = first.id  # also mentioned where the canonical was
    await record_mentions(db_session, [duplicate])
    duplicate.conversation_id = third.id
    await record_mentions(db_session, [duplicate])
    canonical_id = canonical.id

    await merge_entities(db_session, canonical, duplicate)
    await db_session.commit()

    conversations = set(
        (
            await db_session.execute(
                select(EntityMention.conversation_id).where(EntityMention.entity_id == canonical_id)
            )
        ).scalars()
    )
    assert conversations == {first.id, second.id, third.id}


@pytest.mark.asyncio
async def test_people_lists_everyone_most_recent_first(
    client, auth_headers, db_session: AsyncSession
):
    await _marco_in_two_conversations(db_session)
    old, (line,) = await make_conversation(
        db_session, started_at=NOW - timedelta(days=30), texts=("[Tu] Ada mi ha scritto.",)
    )
    ada = make_entity(old, "person", "Ada", source=line, content="Collega di Milano")
    db_session.add(ada)
    await db_session.flush()
    await record_mentions(db_session, [ada])
    conversation, _ = await make_conversation(db_session, started_at=NOW)
    db_session.add_all(
        [
            make_entity(conversation, "task", "Chiamare Marco per Atlas"),
            make_entity(conversation, "task", "Mandare il budget a marco"),
            make_entity(conversation, "task", "Fatto: scrivere a Marco", metadata={"done": True}),
            make_entity(conversation, "task", "Chiamare Marcolini"),  # not Marco
        ]
    )
    await db_session.commit()

    body = (await client.get("/api/people", headers=auth_headers)).json()

    assert [p["name"] for p in body] == ["Marco", "Ada"]
    marco, ada_out = body
    assert marco["role"] == "designer"
    assert marco["conversation_count"] == 2
    assert marco["open_task_count"] == 2
    assert ada_out["about"] == "Collega di Milano"
    assert ada_out["conversation_count"] == 1


@pytest.mark.asyncio
async def test_a_person_has_their_conversations_tasks_and_events(
    client, auth_headers, db_session: AsyncSession
):
    marco, last_week, today = await _marco_in_two_conversations(db_session)
    other, (line,) = await make_conversation(
        db_session, started_at=NOW - timedelta(days=3), title="Gym", texts=("Squat.",)
    )
    db_session.add_all(
        [
            make_entity(other, "task", "Chiamare Marco", source=line),
            make_entity(other, "event", "Cena con Marco", metadata={"event_date": "2026-10-20"}),
            make_entity(other, "event", "Dentista"),
        ]
    )
    await db_session.commit()

    response = await client.get(f"/api/people/{marco.id}", headers=auth_headers)

    assert response.status_code == 200
    body = response.json()
    assert body["name"] == "Marco"
    assert [c["id"] for c in body["conversations"]] == [str(today.id), str(last_week.id)]
    assert [t["name"] for t in body["tasks"]] == ["Chiamare Marco"]
    assert body["tasks"][0]["source_text"] == "Squat."
    assert [e["name"] for e in body["events"]] == ["Cena con Marco"]


@pytest.mark.asyncio
async def test_a_missing_or_non_person_entity_is_404(
    client, auth_headers, db_session: AsyncSession
):
    conversation, _ = await make_conversation(db_session, started_at=NOW)
    task = make_entity(conversation, "task", "Chiamare Ada")
    db_session.add(task)
    await db_session.commit()

    not_a_person = await client.get(f"/api/people/{task.id}", headers=auth_headers)
    missing = await client.get(
        "/api/people/00000000-0000-4000-8000-000000000000", headers=auth_headers
    )

    assert not_a_person.status_code == 404
    assert missing.status_code == 404
