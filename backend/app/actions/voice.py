"""Voice requests: detect "Echo, ..." in transcripts and assemble the spoken command.

A request starts when the user addresses Echo by name at (or near) the start of an
utterance. `find_wake` is a cheap pre-filter run after STT; the voice worker then
assembles the command across the following segments (`collect_command`) and confirms
with the cheap LLM (`is_assistant_request`) before anything is answered or executed.
"""

import logging
import re
import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.chat_session import ChatSession
from app.models.segment import Segment
from app.services.llm_base import LLMMessage, LLMService

logger = logging.getLogger(__name__)

VOICE_SESSION_TITLE = "Voice requests"

# The name must be one of the first WAKE_MAX_POSITION words of the utterance.
WAKE_MAX_POSITION = 4
# Command window (Global Constraints): a pause of 3 s or 15 s after the wake segment start.
PAUSE_MS = 3000
COMMAND_WINDOW = timedelta(seconds=15)
# Stop waiting for pending/processing STT this long after the wake segment arrived.
STT_WAIT_LIMIT = timedelta(seconds=25)
# A continuation starts < 3 s after the previous segment ends and lasts <= 6 s, so it
# arrives within about this many seconds of the previous segment's arrival.
CONTINUATION_WAIT_S = 10

# Requests being answered, per user (hash: segment id -> {"command", "since"}), so the app
# can show "Echo is working on it"; the TTL clears what a crash would leave behind.
WORKING_KEY = "voice:working:{user_id}"
WORKING_TTL_S = 300

# Speaker tag prepended by the STT worker: "[You] " / "[Others] " (older: "[Tu] "/"[Altri] ").
_SPEAKER_TAG = re.compile(r"^\s*\[(?:you|others|tu|altri)\]\s*", re.IGNORECASE)
# Whole word only: an apostrophe glued to the name ("l'eco") is part of another word.
_WAKE = re.compile(
    r"(?<![\w'’])(?:(?:hey|ehi)[\s,]+)?(?:echo|eco)(?![\w'’])", re.IGNORECASE
)
_AFTER_NAME = re.compile(r"[\s,:;.!?\-–—]*")
_PENDING_STT = ("pending", "processing")

ASSISTANT_CHECK_PROMPT = """Echo is a voice assistant the user wears; it hears everything \
the user says. This speech transcript contains the word "Echo" (or "Eco") near its start.
Decide whether the speaker is addressing Echo with a request or a question for it \
(e.g. "Echo, riassumimi le ultime mail", "Hey Echo, what's on my calendar tomorrow?", \
"Ehi Eco, segnami il dentista martedì") or is only mentioning the word (e.g. \
"ho comprato un Echo nuovo", "l'eco della stanza", an Amazon Echo device, an echo sound).
Respond with ONLY a JSON object: {"assistant_request": true} or {"assistant_request": false}."""


def strip_speaker_tag(text: str) -> str:
    """The text without its leading "[You] "/"[Others] "/"[Tu] "/"[Altri] " tag."""
    return _SPEAKER_TAG.sub("", text or "", count=1)


def _match_wake(text: str) -> tuple[int, int] | None:
    """(name start, command start) when the utterance addresses Echo, else None."""
    if not text:
        return None
    tag = _SPEAKER_TAG.match(text)
    body_start = tag.end() if tag else 0
    match = _WAKE.search(text, body_start)
    if match is None:
        return None
    words_before = len(text[body_start:match.start()].split())
    if words_before >= WAKE_MAX_POSITION:
        return None

    separator = _AFTER_NAME.match(text, match.end())
    command_start = separator.end()
    if any(c.isalnum() for c in text[command_start:]):
        return match.start(), command_start
    # Name with nothing after it: an address only when it opens the utterance or is
    # followed by "," / ":" ("Hey Echo", "Ok Echo," + command in the next segment);
    # "ho comprato un Echo" is a mention.
    if words_before == 0 or any(c in ",:" for c in separator.group()):
        return match.start(), len(text)
    return None


def find_wake(text: str) -> int | None:
    """Index in `text` where the command after "Echo" starts; None if not addressed.

    The index may equal len(text) when the utterance is only the name: the command
    then comes from the following segments.
    """
    match = _match_wake(text)
    return None if match is None else match[1]


async def is_assistant_request(llm: LLMService, text: str) -> bool:
    """Ask the cheap LLM whether `text` addresses Echo with a request. Any error -> False."""
    try:
        result = await llm.complete_json(
            [
                LLMMessage(role="system", content=ASSISTANT_CHECK_PROMPT),
                LLMMessage(role="user", content=text),
            ],
            temperature=0.0,
        )
        return isinstance(result, dict) and result.get("assistant_request") is True
    except Exception:
        logger.warning("Voice request check failed; ignoring the utterance", exc_info=True)
        return False


def _follows(wake: Segment, segment: Segment, window_end: datetime) -> bool:
    if segment.id == wake.id or segment.user_id != wake.user_id:
        return False
    if not wake.recorded_at < segment.recorded_at < window_end:
        return False
    # Segments not yet grouped into a conversation (analysis still running) belong too
    return (
        wake.conversation_id is None
        or segment.conversation_id is None
        or segment.conversation_id == wake.conversation_id
    )


async def collect_command(
    db: AsyncSession, wake_segment: Segment, now: datetime
) -> str | None:
    """The full spoken command, or None while it may still be incomplete (wait).

    Joins the text after the name with the following segments of the same user (and
    conversation, when both are grouped), ordered by recording time, until a pause of
    PAUSE_MS, the end of the 15 s window, or a new "Echo, ..." request. Waits while a
    segment in the window is still in STT, but never past STT_WAIT_LIMIT after the wake
    segment arrived; then the stuck segment and what follows are left out. Returns ""
    when there is nothing to ask.
    """
    transcription = wake_segment.transcription
    text = transcription.text if transcription is not None else ""
    match = _match_wake(text or "")
    if match is None:
        return ""

    window_end = wake_segment.recorded_at + COMMAND_WINDOW
    query = (
        select(Segment)
        .where(Segment.user_id == wake_segment.user_id)
        .where(Segment.id != wake_segment.id)
        .where(Segment.recorded_at > wake_segment.recorded_at)
        .where(Segment.recorded_at < window_end)
        .order_by(Segment.recorded_at)
    )
    if wake_segment.conversation_id is not None:
        query = query.where(
            or_(
                Segment.conversation_id == wake_segment.conversation_id,
                Segment.conversation_id.is_(None),
            )
        )
    rows = (await db.execute(query)).scalars().all()
    following = sorted(
        (s for s in rows if _follows(wake_segment, s, window_end)),
        key=lambda s: s.recorded_at,
    )

    give_up_at = wake_segment.received_at + STT_WAIT_LIMIT
    parts = [text[match[1]:].strip()]
    last = wake_segment
    closed = False
    for segment in following:
        if (segment.silence_before_ms or 0) >= PAUSE_MS:
            closed = True
            break
        if segment.transcription_status in _PENDING_STT:
            if now < give_up_at:
                return None
            closed = True
            break
        if segment.transcription_status != "completed" or segment.transcription is None:
            continue  # failed STT: nothing to add
        segment_text = segment.transcription.text or ""
        if find_wake(segment_text) is not None:
            closed = True  # a new request starts here
            break
        parts.append(strip_speaker_tag(segment_text).strip())
        last = segment

    if not closed:
        last_end = last.recorded_at + timedelta(milliseconds=last.duration_ms or 0)
        wait_until = min(
            last.received_at + timedelta(seconds=CONTINUATION_WAIT_S), give_up_at
        )
        if last_end < window_end and now < wait_until:
            return None  # a continuation may still be uploading

    return " ".join(part for part in parts if part)


async def get_or_create_voice_session(db: AsyncSession, user_id: uuid.UUID) -> ChatSession:
    """The user's "Voice requests" chat session (created on first use, not committed).

    Locked until commit: voice answers, photos and action outcomes all rewrite its
    message list, so they take turns instead of overwriting each other.
    """
    result = await db.execute(
        select(ChatSession)
        .where(ChatSession.user_id == user_id)
        .where(ChatSession.kind == "voice")
        .order_by(ChatSession.updated_at.desc())
        .limit(1)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    session = result.scalars().first()
    if session is not None:
        return session
    now = datetime.now(timezone.utc)
    session = ChatSession(
        id=uuid.uuid4(),
        user_id=user_id,
        title=VOICE_SESSION_TITLE,
        kind="voice",
        messages=[],
        created_at=now,
        updated_at=now,
    )
    db.add(session)
    return session
