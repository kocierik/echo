"""Echo noticed (Profile → Memory → About you): once a conversation is summarized, one LLM
call reads only the user's own lines and proposes lasting facts the user states about
themselves. They are suggestions: used in answers only once the user keeps them.

Never anything about health, politics, religion, sex life or orientation, ethnicity or
money troubles (told to the model and checked again on its answer), nothing already known
or discarded, at most 3 per conversation and 20 waiting (the oldest make room).
"""

import logging
import re
import unicodedata
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.conversation import Conversation
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.models.user_fact import UserFact
from app.services import user_facts
from app.services.llm_base import LLMMessage
from app.services.user_facts import FactError

logger = logging.getLogger(__name__)

PER_CONVERSATION = 3
MAX_WORDS_READ = 1500

PROMPT = (
    "From the user's own words in a conversation, list the lasting facts the user states "
    "about themselves: their job, where they live, family and the important people in "
    "their life and who they are, habits, preferences. Only what they say explicitly about "
    "themselves, never guesses; nothing temporary (today's plans, moods). Never anything "
    "about health, politics, religion, sex life or sexual orientation, ethnicity, or money "
    "troubles. Leave out what is already known (listed). One short sentence each, in the "
    'language the user speaks, without "the user" ("Lavora come sviluppatore a Milano"). '
    f'At most {PER_CONVERSATION}. Reply with JSON only: {{"facts": ["..."]}}.'
)

# Checked again on the answer, on whole words (Italian and English): a suggestion about
# these never reaches the user. The prompt is the main guard; this catches what slips by.
_SENSITIVE = re.compile(
    r"\b("
    # Health
    r"malat\w*|diabet\w*|cancro|cancer|tumou?r\w*|diagnos\w*|terapia|terapie|therapy|"
    r"therapies|farmaci|farmaco|medication\w*|psichiatr\w*|psicolog\w*|psychiatr\w*|"
    r"depress\w*|ansia|ansios\w*|anxiety|adhd|autis\w*|celiac\w*|allerg\w*|"
    r"sieropositiv\w*|hiv|incint\w*|gravidanz\w*|pregnan\w*|disabil\w*|handicap|"
    r"chemio\w*|illness|ill|disease\w*|"
    # Religion
    r"religio\w*|cattolic\w*|catholic\w*|cristian\w*|christian\w*|musulman\w*|muslim\w*|"
    r"islam\w*|ebre[oaie]|ebraic\w*|jewish|jew|buddist\w*|buddhist\w*|ateo|atea|atei|"
    r"atheist\w*|messa|chiesa|church|moschea|mosque|sinagoga|synagogue|prega|prego|"
    r"pregare|preghiera|pray\w*|faith|"
    # Politics
    r"politic\w*|partito|vota|voto|votare|vote|votes|voted|voting|elezion\w*|election\w*|"
    r"destra|sinistra|comunist\w*|fascist\w*|leghist\w*|democrat\w*|republican\w*|"
    r"conservative|liberal|left-wing|right-wing|"
    # Sex life and orientation
    r"gay|lesbic\w*|lesbian\w*|omosessual\w*|bisessual\w*|sessual\w*|homosexual\w*|"
    r"bisexual\w*|sexual\w*|sex|transgender\w*|trans|queer|orientamento|orientation|"
    # Ethnicity
    r"etni\w*|razza|razziale|ethnic\w*|race|"
    # Money troubles
    r"debit\w*|prestit\w*|fallit\w*|disoccupat\w*|pignorament\w*|sfratt\w*|debt\w*|"
    r"loan\w*|bankrupt\w*|unemploy\w*|evict\w*"
    r")\b"
    r"|\bcan'?t pay\b|\bcannot pay\b|\bnon riesce a pagare\b",
    re.IGNORECASE,
)


def is_sensitive(text: str) -> bool:
    """Whether a suggested fact touches health, religion, politics, sex life or
    orientation, ethnicity or money troubles."""
    plain = unicodedata.normalize("NFD", text)
    plain = "".join(c for c in plain if not unicodedata.combining(c)).replace("’", "'")
    return _SENSITIVE.search(plain) is not None


async def _own_words(db: AsyncSession, conversation: Conversation) -> str:
    rows = await db.execute(
        select(Transcription.text)
        .join(Segment, Segment.id == Transcription.segment_id)
        .where(Segment.conversation_id == conversation.id, Segment.speaker == "self")
        .order_by(Segment.recorded_at)
    )
    words = " ".join(text.strip() for (text,) in rows.all() if text and text.strip()).split()
    return " ".join(words[:MAX_WORDS_READ])


async def suggest_facts(db: AsyncSession, llm, conversation: Conversation) -> list[UserFact]:
    """The new suggestions from this conversation (the caller commits); none when the user
    said nothing about themselves, or the model's answer cannot be read."""
    own = await _own_words(db, conversation)
    if not own:
        return []
    user_id = conversation.user_id
    known = list(await db.scalars(select(UserFact).where(UserFact.user_id == user_id)))
    listed = "\n".join(f"- {f.text}" for f in known if f.status != "discarded") or "- (none)"
    # Turned down or deleted by the user: not again, not even in other words
    refused = "\n".join(f"- {f.text}" for f in known if f.status == "discarded")
    never = (
        f"\n\nNever suggest these again, nor the same in other words:\n{refused}"
        if refused
        else ""
    )
    try:
        answer = await llm.complete_json([
            LLMMessage(role="system", content=PROMPT),
            LLMMessage(
                role="user",
                content=f"Already known:\n{listed}{never}\n\nThe user's words:\n{own}",
            ),
        ])
    except Exception:
        logger.warning("[Facts] Could not read suggestions", exc_info=True)
        return []
    found = answer.get("facts") if isinstance(answer, dict) else None
    if not isinstance(found, list):
        return []

    added: list[UserFact] = []
    seen = {user_facts.normalize(f.text) for f in known}
    for raw in found:
        if len(added) >= PER_CONVERSATION:
            break
        if not isinstance(raw, str) or is_sensitive(raw):
            continue
        try:
            text = user_facts.clean(raw)
        except FactError:
            continue
        if user_facts.normalize(text) in seen:
            continue
        seen.add(user_facts.normalize(text))
        fact = UserFact(
            id=uuid.uuid4(), user_id=user_id, text=text, status="suggested",
            source="conversation", conversation_id=conversation.id,
        )
        db.add(fact)
        added.append(fact)
    if added:
        await db.flush()
        await _make_room(db, user_id)
    return added


async def _make_room(db: AsyncSession, user_id: uuid.UUID) -> None:
    waiting = list(await db.scalars(
        select(UserFact)
        .where(UserFact.user_id == user_id, UserFact.status == "suggested")
        .order_by(UserFact.created_at.desc(), UserFact.id)
    ))
    for old in waiting[user_facts.MAX_SUGGESTED:]:
        await db.delete(old)
