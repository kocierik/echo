"""What a conversation gets once it is closed and read whole: its title, summary, emoji
and topics, then what the user said about themselves and the saved people's facts.

One place, for the summaries loop and for a conversation analysed again (a correction, the
transcription of the whole): a reanalysed conversation used to get its summary only, never
its topics or its facts.
"""

import logging

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.conversation import Conversation
from app.models.entity import Entity
from app.models.entity_mention import EntityMention
from app.services.analysis_pipeline import generate_conversation_summary
from app.services.fact_suggestions import suggest_facts
from app.services.llm_base import LLMService
from app.services.person_facts import extract_person_facts
from app.services.topics import normalize_topics
from app.workers.retry import retry_with_backoff

logger = logging.getLogger(__name__)


async def write_summary(
    db: AsyncSession, llm: LLMService, conversation: Conversation, full_text: str
) -> None:
    """Summarize `conversation` from `full_text` (no commit). The summary's failure is the
    caller's (RetryExhaustedError); the facts are best effort and never cost the summary."""
    result = await retry_with_backoff(
        generate_conversation_summary,
        llm,
        full_text,
        operation_name=f"Summary conversation {conversation.id}",
    )
    conversation.title = result.title
    conversation.summary = result.summary
    conversation.emoji = result.emoji
    person_names = (
        await db.execute(
            select(Entity.name)
            .join(EntityMention, EntityMention.entity_id == Entity.id)
            .where(EntityMention.conversation_id == conversation.id)
            .where(Entity.user_id == conversation.user_id)
            .where(Entity.entity_type == "person")
        )
    ).scalars().all()
    conversation.topics = normalize_topics(result.topics, person_names) or None
    # What the user said about themselves: suggestions for About you
    try:
        async with db.begin_nested():
            await suggest_facts(db, llm, conversation)
    except Exception:
        logger.warning("[Summaries] No fact suggestions for %s", conversation.id, exc_info=True)
    try:
        async with db.begin_nested():
            await extract_person_facts(db, llm, conversation)
    except Exception as exc:
        logger.warning(
            "[Summaries] No person facts for %s (%s)", conversation.id, type(exc).__name__
        )
