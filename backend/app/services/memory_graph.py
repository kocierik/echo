import uuid
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from itertools import combinations

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.entity_mention import EntityMention
from app.services.topics import normalize_topics

MAX_PEOPLE = 30
MAX_TOPICS = 20


async def memory_graph(db: AsyncSession, user_id: uuid.UUID, days: int) -> dict:
    """Build a weighted graph from a user's person mentions and conversation topics."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days) if days > 0 else None
    in_window = [Conversation.user_id == user_id]
    if cutoff is not None:
        in_window.append(Conversation.started_at >= cutoff)

    person_rows = await db.execute(
        select(
            Entity.id,
            Entity.name,
            func.count(func.distinct(Conversation.id)).label("weight"),
        )
        .join(EntityMention, EntityMention.entity_id == Entity.id)
        .join(Conversation, Conversation.id == EntityMention.conversation_id)
        .where(
            Entity.user_id == user_id,
            Entity.entity_type == "person",
            *in_window,
        )
        .group_by(Entity.id)
        .order_by(func.count(func.distinct(Conversation.id)).desc(), Entity.name, Entity.id)
        .limit(MAX_PEOPLE)
    )
    people = [(person_id, name, weight) for person_id, name, weight in person_rows]
    if not people:
        return {
            "nodes": [{"id": "you", "kind": "you", "label": "You", "weight": 0}],
            "edges": [],
        }

    person_ids = [person_id for person_id, _, _ in people]
    mention_rows = await db.execute(
        select(Entity.id, Conversation.id)
        .join(EntityMention, EntityMention.entity_id == Entity.id)
        .join(Conversation, Conversation.id == EntityMention.conversation_id)
        .where(
            Entity.id.in_(person_ids),
            Entity.user_id == user_id,
            Entity.entity_type == "person",
            *in_window,
        )
        .distinct()
    )
    person_conversations: dict[uuid.UUID, set[uuid.UUID]] = defaultdict(set)
    conversation_people: dict[uuid.UUID, set[uuid.UUID]] = defaultdict(set)
    for person_id, conversation_id in mention_rows:
        person_conversations[person_id].add(conversation_id)
        conversation_people[conversation_id].add(person_id)
    conversation_ids = list(conversation_people)
    topic_rows = await db.execute(
        select(Conversation.id, Conversation.topics)
        .where(
            Conversation.id.in_(conversation_ids),
            Conversation.user_id == user_id,
            *in_window,
        )
    )
    topic_conversations: dict[str, set[uuid.UUID]] = defaultdict(set)
    person_topic_conversations: dict[tuple[uuid.UUID, str], set[uuid.UUID]] = defaultdict(set)
    for conversation_id, raw_topics in topic_rows:
        topics = set(normalize_topics(raw_topics, []))
        for topic in topics:
            topic_conversations[topic].add(conversation_id)
            for person_id in conversation_people[conversation_id]:
                person_topic_conversations[(person_id, topic)].add(conversation_id)

    topics = sorted(
        (
            (topic, len(conversation_ids_for_topic))
            for topic, conversation_ids_for_topic in topic_conversations.items()
            if len(conversation_ids_for_topic) >= 2
        ),
        key=lambda item: (-item[1], item[0]),
    )[:MAX_TOPICS]
    retained_topics = {topic for topic, _ in topics}

    nodes = [{"id": "you", "kind": "you", "label": "You", "weight": len(conversation_ids)}]
    nodes.extend(
        {
            "id": f"person:{person_id}",
            "kind": "person",
            "label": name,
            "weight": len(person_conversations[person_id]),
        }
        for person_id, name, _ in people
    )
    nodes.extend(
        {"id": f"topic:{topic}", "kind": "topic", "label": topic, "weight": weight}
        for topic, weight in topics
    )

    edges = [
        {"a": "you", "b": f"person:{person_id}", "weight": len(person_conversations[person_id])}
        for person_id, _, _ in people
    ]
    name_by_id = {person_id: name for person_id, name, _ in people}
    rank_by_id = {person_id: index for index, (person_id, _, _) in enumerate(people)}
    pair_weights: dict[tuple[uuid.UUID, uuid.UUID], int] = defaultdict(int)
    for person_set in conversation_people.values():
        ordered_people = sorted(person_set, key=rank_by_id.__getitem__)
        for first, second in combinations(ordered_people, 2):
            pair_weights[(first, second)] += 1
    edges.extend(
        {
            "a": f"person:{first}",
            "b": f"person:{second}",
            "weight": weight,
        }
        for (first, second), weight in sorted(
            pair_weights.items(),
            key=lambda item: (rank_by_id[item[0][0]], rank_by_id[item[0][1]]),
        )
    )
    edges.extend(
        {
            "a": f"person:{person_id}",
            "b": f"topic:{topic}",
            "weight": len(conversation_ids_for_edge),
        }
        for (person_id, topic), conversation_ids_for_edge in sorted(
            person_topic_conversations.items(),
            key=lambda item: (name_by_id[item[0][0]], item[0][1]),
        )
        if topic in retained_topics
    )
    return {"nodes": nodes, "edges": edges}
