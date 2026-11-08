"""Who is speaking: segments' voice fingerprints matched to the user's known voices.

- The user's own voice comes from a recording made for it (`enroll_self`) and grows with
  every transcript correction to "You".
- Other voices are named by the user in a transcript (`assign_voice`): the profile is
  created or refined from that segment, and the conversation's other segments with the
  same voice are labelled too.
- A new segment (`recognize`) is "You" when it matches the user's voice, a named person
  when it matches theirs (or "Marco?" to confirm when it nearly does), else "Others".
  Without the user's own profile the energy rule still decides "You" / "Others".
"""

import logging
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import undefer

from app.core.config import settings
from app.models.entity import Entity
from app.models.segment import Segment
from app.models.voice_profile import VoiceProfile
from app.services.transcription_enhancer import speaker_prefix
from app.services.voice_embedding import cosine, normalize

logger = logging.getLogger(__name__)

SELF_NAME = "You"
# Segments still being transcribed delay an enrollment this long at most
ENROLL_GRACE = timedelta(seconds=90)
_TAG = re.compile(r"^\s*\[(?:you|others|tu|altri)\]\s*", re.IGNORECASE)


@dataclass
class Match:
    profile: VoiceProfile
    similarity: float


def _now() -> datetime:
    return datetime.now(timezone.utc)


async def list_profiles(db: AsyncSession, user_id: uuid.UUID) -> list[VoiceProfile]:
    result = await db.execute(
        select(VoiceProfile)
        .where(VoiceProfile.user_id == user_id)
        .order_by(VoiceProfile.is_self.desc(), VoiceProfile.name)
    )
    return list(result.scalars())


def best_match(profiles: list[VoiceProfile], embedding) -> Match | None:
    scored = [Match(p, cosine(p.embedding, embedding)) for p in profiles]
    return max(scored, key=lambda m: m.similarity, default=None)


def add_sample(profile: VoiceProfile, embedding) -> None:
    """Fold one more segment into the profile (running mean, normalized)."""
    n = profile.sample_count
    mean = [(float(m) * n + float(e)) / (n + 1) for m, e in zip(profile.embedding, embedding)]
    profile.embedding = normalize(mean)
    profile.sample_count = n + 1
    profile.updated_at = _now()


def retag(text: str | None, speaker: str) -> str | None:
    """The transcript text with the speaker tag of `speaker` (the leading tag replaced)."""
    if text is None:
        return None
    return f"{speaker_prefix(speaker)}{_TAG.sub('', text)}"


def _label(segment: Segment, speaker: str) -> None:
    segment.speaker = speaker
    transcription = segment.transcription
    if transcription is not None:
        transcription.text = retag(transcription.text, speaker)
        transcription.speaker_label = speaker


def recognize(segment: Segment, embedding, profiles: list[VoiceProfile]) -> str | None:
    """Set the segment's voice fields; the speaker ("self"/"other"), or None to leave it to
    the energy rule (no own profile and no sure match)."""
    has_self = any(p.is_self for p in profiles)
    match = best_match(profiles, embedding)
    if match is not None and match.similarity >= settings.voice_suggest_threshold:
        segment.voice_similarity = round(match.similarity, 4)
        if match.similarity >= settings.voice_match_threshold:
            segment.voice_profile_id = match.profile.id
            segment.voice_match = "auto"
            return "self" if match.profile.is_self else "other"
        if not match.profile.is_self:
            segment.voice_profile_id = match.profile.id
            segment.voice_match = "suggested"
    return "other" if has_self else None


def group_voices(embeddings: list, threshold: float) -> list[int]:
    """Each fingerprint's group, in order: it joins the most similar group so far when
    at least `threshold` alike, else starts one (groups numbered from 0)."""
    centroids: list[list[float]] = []
    sizes: list[int] = []
    groups: list[int] = []
    for embedding in embeddings:
        scores = [cosine(centroid, embedding) for centroid in centroids]
        best = max(range(len(scores)), key=scores.__getitem__, default=None)
        if best is not None and scores[best] >= threshold:
            n = sizes[best]
            centroids[best] = normalize([
                (float(c) * n + float(e)) / (n + 1) for c, e in zip(centroids[best], embedding)
            ])
            sizes[best] = n + 1
            groups.append(best)
        else:
            centroids.append(normalize([float(e) for e in embedding]))
            sizes.append(1)
            groups.append(len(centroids) - 1)
    return groups


async def number_unknown_voices(db: AsyncSession, conversation_id: uuid.UUID) -> int:
    """A closed conversation's unknown voices told apart: with two or more, each gets its
    number ("Person 2", "Person 3"; the user is the first). How many there were."""
    unknown = list(await db.scalars(
        select(Segment)
        .options(undefer(Segment.voice_embedding))
        .where(Segment.conversation_id == conversation_id)
        .where(Segment.speaker == "other", Segment.voice_profile_id.is_(None))
        .where(Segment.voice_embedding.is_not(None))
        .order_by(Segment.recorded_at)
    ))
    groups = group_voices([s.voice_embedding for s in unknown], settings.voice_match_threshold)
    count = len(set(groups))
    if count >= 2:
        for segment, group in zip(unknown, groups):
            segment.voice_group = group + 2
    return count


@dataclass
class Enrollment:
    status: str  # "done", "waiting" (segments still being transcribed) or "no_speech"
    profile: VoiceProfile | None = None
    segments: int = 0


async def enroll_self(
    db: AsyncSession,
    user_id: uuid.UUID,
    started_at: datetime,
    ended_at: datetime,
    now: datetime | None = None,
) -> Enrollment:
    """The user's voice from what the wearable recorded while they read the text.

    Replaces an earlier own profile. Called again until it is not "waiting".
    """
    now = now or _now()
    rows = (
        await db.execute(
            select(Segment)
            .options(undefer(Segment.voice_embedding))
            .where(Segment.user_id == user_id)
            .where(Segment.recorded_at >= started_at, Segment.recorded_at <= ended_at)
        )
    ).scalars().all()
    pending = [s for s in rows if s.transcription_status in ("pending", "processing")]
    if pending and now < ended_at + ENROLL_GRACE:
        return Enrollment("waiting")
    samples = [s for s in rows if s.voice_embedding is not None]
    if not samples:
        return Enrollment("no_speech")

    profile = (
        await db.execute(
            select(VoiceProfile).where(VoiceProfile.user_id == user_id, VoiceProfile.is_self)
        )
    ).scalar_one_or_none()
    if profile is None:
        profile = VoiceProfile(user_id=user_id, name=SELF_NAME, is_self=True, sample_count=0)
        db.add(profile)
    profile.sample_count = 0
    profile.embedding = [0.0] * len(samples[0].voice_embedding)
    for segment in samples:
        add_sample(profile, segment.voice_embedding)
    await db.flush()
    for segment in samples:
        segment.voice_profile_id = profile.id
        segment.voice_match = "confirmed"
        _label(segment, "self")
    await db.commit()
    return Enrollment("done", profile, len(samples))


async def learn_self(db: AsyncSession, segment: Segment) -> None:
    """A transcript correction to "You": the segment's voice refines the own profile."""
    embedding = (
        await db.execute(select(Segment.voice_embedding).where(Segment.id == segment.id))
    ).scalar_one_or_none()
    if embedding is None:
        return
    profile = (
        await db.execute(
            select(VoiceProfile).where(
                VoiceProfile.user_id == segment.user_id, VoiceProfile.is_self
            )
        )
    ).scalar_one_or_none()
    if profile is None:
        profile = VoiceProfile(
            user_id=segment.user_id,
            name=SELF_NAME,
            is_self=True,
            embedding=list(embedding),
            sample_count=1,
        )
        db.add(profile)
        await db.flush()
    else:
        add_sample(profile, embedding)
    segment.voice_profile_id = profile.id
    segment.voice_match = "confirmed"


async def _person_named(db: AsyncSession, user_id: uuid.UUID, name: str) -> Entity | None:
    result = await db.execute(
        select(Entity)
        .where(Entity.user_id == user_id, Entity.entity_type == "person")
        .where(func.lower(Entity.name) == name.strip().lower())
        .limit(1)
    )
    return result.scalar_one_or_none()


@dataclass
class Assignment:
    profile: VoiceProfile
    relabelled: int  # other segments of the conversation recognised with it
    learned: bool  # False when the segment had no fingerprint (audio already gone)


async def assign_voice(
    db: AsyncSession,
    segment: Segment,
    *,
    is_self: bool = False,
    name: str | None = None,
    person_id: uuid.UUID | None = None,
) -> Assignment:
    """The user says whose voice a segment is: "me", a person of theirs, or a new name."""
    user_id = segment.user_id
    embedding = (
        await db.execute(select(Segment.voice_embedding).where(Segment.id == segment.id))
    ).scalar_one_or_none()

    person = None
    if not is_self:
        if person_id is not None:
            person = await db.get(Entity, person_id)
            if person is None or person.user_id != user_id or person.entity_type != "person":
                raise LookupError("person not found")
            name = person.name
        name = (name or "").strip()
        if not name:
            raise ValueError("a name or a person is needed")
        person = person or await _person_named(db, user_id, name)

    query = select(VoiceProfile).where(VoiceProfile.user_id == user_id)
    if is_self:
        query = query.where(VoiceProfile.is_self)
    elif person is not None:
        query = query.where(VoiceProfile.person_id == person.id)
    else:
        query = query.where(
            ~VoiceProfile.is_self, func.lower(VoiceProfile.name) == name.lower()
        )
    profile = (await db.execute(query.limit(1))).scalar_one_or_none()

    if profile is None:
        if embedding is None:
            raise ValueError("this segment has no voice fingerprint to start a profile from")
        profile = VoiceProfile(
            user_id=user_id,
            name=SELF_NAME if is_self else name,
            is_self=is_self,
            person_id=person.id if person is not None else None,
            embedding=list(embedding),
            sample_count=1,
        )
        db.add(profile)
        await db.flush()
    elif embedding is not None:
        add_sample(profile, embedding)

    segment.voice_profile_id = profile.id
    segment.voice_match = "confirmed"
    segment.voice_similarity = None
    _label(segment, "self" if is_self else "other")

    relabelled = 0
    if segment.conversation_id is not None:
        relabelled = await _relabel_conversation(db, segment, profile)
    await db.commit()
    return Assignment(profile, relabelled, embedding is not None)


async def _relabel_conversation(
    db: AsyncSession, named: Segment, profile: VoiceProfile
) -> int:
    """The conversation's other segments with this voice, unless the user decided them."""
    others = (
        await db.execute(
            select(Segment)
            .options(undefer(Segment.voice_embedding))
            .where(Segment.conversation_id == named.conversation_id, Segment.id != named.id)
            .where(Segment.voice_embedding.isnot(None))
            .where(func.coalesce(Segment.voice_match, "") != "confirmed")
        )
    ).scalars().all()
    count = 0
    for segment in others:
        similarity = cosine(profile.embedding, segment.voice_embedding)
        if similarity >= settings.voice_match_threshold:
            segment.voice_profile_id = profile.id
            segment.voice_match = "auto"
            segment.voice_similarity = round(similarity, 4)
            _label(segment, "self" if profile.is_self else "other")
            count += 1
    return count


async def reject_suggestion(db: AsyncSession, segment: Segment) -> None:
    """Not that person: the transcript stops asking."""
    if segment.voice_match in ("suggested", "auto"):
        segment.voice_profile_id = None
        segment.voice_match = None
        segment.voice_similarity = None
    await db.commit()


async def delete_profile(db: AsyncSession, profile: VoiceProfile) -> None:
    """The fingerprint goes; segments keep their You/Others label but lose the name."""
    await db.execute(
        update(Segment)
        .where(Segment.voice_profile_id == profile.id)
        .values(voice_profile_id=None, voice_match=None, voice_similarity=None)
    )
    await db.delete(profile)
    await db.commit()
