import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Conversation, Entity, EntityMention
from tests.conftest import TEST_USER_ID

NOW = datetime.now(timezone.utc)


async def _conversation(
    db: AsyncSession,
    *,
    topics: list[str] | None = None,
    started_at: datetime = NOW,
    user_id: uuid.UUID = TEST_USER_ID,
) -> Conversation:
    conversation = Conversation(
        user_id=user_id,
        title="Memory graph test",
        summary="",
        topics=topics,
        started_at=started_at,
        ended_at=started_at + timedelta(minutes=5),
        analysis_status="completed",
    )
    db.add(conversation)
    await db.flush()
    return conversation


async def _mention(
    db: AsyncSession,
    conversation: Conversation,
    person: Entity,
) -> None:
    db.add(EntityMention(entity_id=person.id, conversation_id=conversation.id))
    await db.flush()


async def _person(db: AsyncSession, user_id: uuid.UUID, name: str) -> Entity:
    person = Entity(
        user_id=user_id,
        entity_type="person",
        name=name,
        metadata_={},
    )
    db.add(person)
    await db.flush()
    return person


@pytest.mark.asyncio
async def test_graph_weights_and_edges(client, auth_headers, db_session: AsyncSession):
    marco = await _person(db_session, TEST_USER_ID, "Marco")
    ada = await _person(db_session, TEST_USER_ID, "Ada")
    first = await _conversation(db_session, topics=["atlas"])
    second = await _conversation(db_session, topics=[])
    third = await _conversation(db_session, topics=["atlas"])
    fourth = await _conversation(db_session, topics=[])
    await _mention(db_session, first, marco)
    await _mention(db_session, first, ada)
    await _mention(db_session, second, ada)
    await _mention(db_session, third, marco)
    await _mention(db_session, fourth, marco)
    await db_session.commit()

    response = await client.get("/api/memory-graph", headers=auth_headers)

    assert response.status_code == 200
    body = response.json()
    nodes = {node["id"]: node for node in body["nodes"]}
    edges = {(edge["a"], edge["b"]): edge["weight"] for edge in body["edges"]}
    marco_id = f"person:{marco.id}"
    ada_id = f"person:{ada.id}"
    assert nodes["you"]["weight"] == 4
    assert nodes[marco_id]["weight"] == 3
    assert nodes[ada_id]["weight"] == 2
    assert nodes["topic:atlas"]["weight"] == 2
    assert edges[("you", marco_id)] == 3
    assert edges[("you", ada_id)] == 2
    assert edges[(marco_id, ada_id)] == 1
    assert edges[(marco_id, "topic:atlas")] == 2


@pytest.mark.asyncio
async def test_graph_window_and_thresholds(client, auth_headers, db_session: AsyncSession):
    marco = await _person(db_session, TEST_USER_ID, "Marco")
    old_date = NOW - timedelta(days=400)
    old_one = await _conversation(db_session, topics=["old topic"], started_at=old_date)
    old_two = await _conversation(
        db_session, topics=["old topic"], started_at=old_date + timedelta(hours=1)
    )
    recent = await _conversation(
        db_session, topics=["single topic"], started_at=NOW - timedelta(days=1)
    )
    future = await _conversation(
        db_session, topics=["future topic"], started_at=NOW + timedelta(days=1)
    )
    for conversation in (old_one, old_two, recent, future):
        await _mention(db_session, conversation, marco)
    await db_session.commit()

    windowed = await client.get("/api/memory-graph?days=30", headers=auth_headers)
    all_time = await client.get("/api/memory-graph?days=0", headers=auth_headers)

    windowed_body = windowed.json()
    all_time_body = all_time.json()
    assert {node["id"] for node in windowed_body["nodes"]} == {
        "you",
        f"person:{marco.id}",
    }
    assert next(node for node in windowed_body["nodes"] if node["id"] == "you")["weight"] == 1
    assert next(
        node for node in windowed_body["nodes"] if node["id"] == f"person:{marco.id}"
    )["weight"] == 1
    all_time_nodes = {node["id"]: node for node in all_time_body["nodes"]}
    assert all_time_nodes["you"]["weight"] == 4
    assert all_time_nodes[f"person:{marco.id}"]["weight"] == 4
    assert all_time_nodes["topic:old topic"]["weight"] == 2
    assert "topic:single topic" not in all_time_nodes


@pytest.mark.asyncio
async def test_graph_limits(client, auth_headers, db_session: AsyncSession):
    people = [
        await _person(db_session, TEST_USER_ID, f"Person {index:02}")
        for index in range(31)
    ]
    for person in people[:30]:
        conversation = await _conversation(db_session)
        await _mention(db_session, conversation, person)

    primary = people[30]
    for topic_index in range(21):
        topic = f"topic-{topic_index:02}"
        for _ in range(2 if topic_index != 20 else 3):
            conversation = await _conversation(db_session, topics=[topic])
            await _mention(db_session, conversation, primary)
    await db_session.commit()

    response = await client.get("/api/memory-graph", headers=auth_headers)

    assert response.status_code == 200
    body = response.json()
    person_ids = {node["id"] for node in body["nodes"] if node["kind"] == "person"}
    topic_ids = {node["id"] for node in body["nodes"] if node["kind"] == "topic"}
    node_ids = {node["id"] for node in body["nodes"]}
    assert len(person_ids) == 30
    assert f"person:{primary.id}" in person_ids
    assert "person:" + str(people[29].id) not in person_ids
    assert len(topic_ids) == 20
    assert "topic:topic-20" in topic_ids
    assert "topic:topic-19" not in topic_ids
    assert all(edge["a"] in node_ids and edge["b"] in node_ids for edge in body["edges"])


@pytest.mark.asyncio
async def test_graph_days_validation(client, auth_headers):
    negative = await client.get("/api/memory-graph?days=-1", headers=auth_headers)
    too_many = await client.get("/api/memory-graph?days=3651", headers=auth_headers)

    assert negative.status_code == 422
    assert too_many.status_code == 422


@pytest.mark.asyncio
async def test_graph_with_no_people_is_only_you(
    client, auth_headers, db_session: AsyncSession
):
    await _conversation(db_session, topics=["atlas"])
    await db_session.commit()

    response = await client.get("/api/memory-graph", headers=auth_headers)

    assert response.status_code == 200
    assert response.json() == {
        "nodes": [{"id": "you", "kind": "you", "label": "You", "weight": 0}],
        "edges": [],
    }


@pytest.mark.asyncio
async def test_graph_is_scoped_to_authenticated_user(
    client, auth_headers, db_session: AsyncSession
):
    other_user_id = uuid.UUID("b0000000-0000-4000-8000-000000000002")
    other_person = await _person(db_session, other_user_id, "Other User")
    other_conversation = await _conversation(
        db_session, topics=["private topic"], user_id=other_user_id
    )
    await _mention(db_session, other_conversation, other_person)
    await db_session.commit()

    response = await client.get("/api/memory-graph", headers=auth_headers)

    assert response.status_code == 200
    assert response.json() == {
        "nodes": [{"id": "you", "kind": "you", "label": "You", "weight": 0}],
        "edges": [],
    }


@pytest.mark.asyncio
async def test_a_deleted_person_leaves_the_graph_and_their_facts_go(
    client, auth_headers, db_session: AsyncSession
):
    from app.models.person_fact import PersonFact

    person = await _person(db_session, TEST_USER_ID, "Marco")
    conversation = await _conversation(db_session)
    await _mention(db_session, conversation, person)
    fact = PersonFact(
        user_id=TEST_USER_ID,
        person_id=person.id,
        text="Works in design",
        category="work",
        quote="Marco lavora nel design.",
        status="current",
    )
    db_session.add(fact)
    await db_session.commit()

    deleted = await client.delete(f"/api/entities/{person.id}", headers=auth_headers)
    graph = await client.get("/api/memory-graph", headers=auth_headers)
    db_session.expire_all()

    assert deleted.status_code == 204
    assert graph.json() == {
        "nodes": [{"id": "you", "kind": "you", "label": "You", "weight": 0}],
        "edges": [],
    }
    assert await db_session.get(PersonFact, fact.id) is None
