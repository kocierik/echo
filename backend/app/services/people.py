"""How a person entity is recognised in text: shared by the People screen and memory search."""

import re

from sqlalchemy import or_, select

from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.entity_mention import EntityMention


def name_key(name: str) -> str:
    """The word a person is called by: the first name, or the whole name when the first
    is under three letters (too ambiguous)."""
    words = name.split()
    return words[0] if words and len(words[0]) >= 3 else name.strip()


def name_pattern(name: str) -> str:
    """A case-insensitive whole-word Postgres regex for the person's first name.

    "Marco Rossi" matches "Chiamare Marco" but not "Marcolini".
    """
    return r"\m" + re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", name_key(name)) + r"\M"


def names_person(name: str, text: str) -> bool:
    """The same rule in Python: does `text` name this person?"""
    key = name_key(name)
    if not key:
        return False
    return re.search(rf"(?<!\w){re.escape(key)}(?!\w)", text, re.IGNORECASE) is not None


def naming(name: str):
    """Entities whose name or content names the person."""
    pattern = name_pattern(name)
    return or_(Entity.name.op("~*")(pattern), Entity.content.op("~*")(pattern))


def person_conversations(person: Entity):
    """Ids of the conversations the person was mentioned in."""
    return select(EntityMention.conversation_id).where(EntityMention.entity_id == person.id)


def in_person_conversations(person: Entity):
    mentioned = person_conversations(person)
    if person.conversation_id is None:
        return Conversation.id.in_(mentioned)
    return or_(Conversation.id.in_(mentioned), Conversation.id == person.conversation_id)
