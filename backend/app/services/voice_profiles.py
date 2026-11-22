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

from pgvector.sqlalchemy import Vector
from sqlalchemy import func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import undefer

from app.core.config import settings
from app.models.entity import Entity
from app.models.segment import Segment
from app.models.transcription import Transcription
from app.models.voice_profile import VoiceProfile
from app.services.speaker_detector import CALIBRATION_SEGMENTS, compute_threshold
from app.services.transcription_enhancer import speaker_prefix
from app.services.voice_embedding import cosine, normalize

logger = logging.getLogger(__name__)

SELF_NAME = "You"
# Segments still being transcribed delay an enrollment this long at most
ENROLL_GRACE = timedelta(seconds=90)
# A segment is at most this long (firmware SEGMENT_DURATION_MS is 25 s)
SEGMENT_REACH = timedelta(seconds=60)


def _read_during(segment: Segment, started_at: datetime, ended_at: datetime) -> bool:
    """Half of the segment, or 5 s of it, recorded while the text was read: a 25 s
    segment starts before the reading or ends after it."""
    length = timedelta(milliseconds=segment.duration_ms)
    overlap = min(segment.recorded_at + length, ended_at) - max(segment.recorded_at, started_at)
    return overlap >= min(length / 2, timedelta(seconds=5))
_TAG = re.compile(r"^\s*\[(?:you|others|tu|altri)\]\s*", re.IGNORECASE)


@dataclass
class Match:
    profile: VoiceProfile
    similarity: float
    # Ahead of the next closest profile (1 with none)
    lead: float = 1.0


def _now() -> datetime:
    return datetime.now(timezone.utc)


async def list_profiles(db: AsyncSession, user_id: uuid.UUID) -> list[VoiceProfile]:
    result = await db.execute(
        select(VoiceProfile)
        .where(VoiceProfile.user_id == user_id)
        .order_by(VoiceProfile.is_self.desc(), VoiceProfile.name)
    )
    return list(result.scalars())


@dataclass
class VoiceContext:
    """What a segment's fingerprint is read against, besides the profiles."""

    # The mean of the user's recent fingerprints: the pendant's own sound, the same in
    # every voice through it (None: too few fingerprints yet, compared raw)
    center: list[float] | None = None
    # From this audio energy a segment is loud: most likely the user, near the microphone
    loud_from: int | None = None


async def voice_context(db: AsyncSession, user_id: uuid.UUID) -> VoiceContext:
    recent = (
        select(Segment.voice_embedding)
        .where(Segment.user_id == user_id, Segment.voice_embedding.isnot(None))
        .order_by(Segment.received_at.desc())
        .limit(300)
        .subquery()
    )
    count, center = (
        await db.execute(
            select(func.count(), func.avg(recent.c.voice_embedding, type_=Vector(256)))
        )
    ).one()
    energies = (await db.scalars(
        select(Segment.audio_energy)
        .where(Segment.user_id == user_id, Segment.audio_energy.isnot(None))
        .order_by(Segment.recorded_at.desc())
        .limit(100)
    )).all()
    return VoiceContext(
        center=(
            [float(x) for x in center]
            if center is not None and count >= settings.voice_center_min_segments
            else None
        ),
        loud_from=(
            compute_threshold(list(energies), settings.voice_loud_percentile)
            if len(energies) >= CALIBRATION_SEGMENTS
            else None
        ),
    )


def voice_similarity(profile_embedding, embedding, center) -> float:
    if center is None:
        return cosine(profile_embedding, embedding)
    return cosine(
        normalize([float(p) - c for p, c in zip(profile_embedding, center)]),
        normalize([float(e) - c for e, c in zip(embedding, center)]),
    )


def voice_thresholds(centered: bool) -> tuple[float, float, float]:
    """(match, suggest, margin) for raw or centered fingerprints."""
    if centered:
        return (
            settings.voice_centered_match_threshold,
            settings.voice_centered_suggest_threshold,
            settings.voice_centered_margin,
        )
    return (
        settings.voice_match_threshold,
        settings.voice_suggest_threshold,
        settings.voice_match_margin,
    )


def best_match(
    profiles: list[VoiceProfile], embedding, center: list[float] | None = None
) -> Match | None:
    """The closest profile; with `center`, compared with the pendant's sound taken away."""
    scored = sorted(
        (Match(p, voice_similarity(p.embedding, embedding, center)) for p in profiles),
        key=lambda m: -m.similarity,
    )
    if not scored:
        return None
    if len(scored) > 1:
        scored[0].lead = scored[0].similarity - scored[1].similarity
    return scored[0]


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


def label_speaker(segment: Segment, speaker: str) -> None:
    """The segment and its transcript said by `speaker` ("self"/"other")."""
    segment.speaker = speaker
    transcription = segment.transcription
    if transcription is not None:
        transcription.text = retag(transcription.text, speaker)
        transcription.speaker_label = speaker


def recognize(
    segment: Segment,
    embedding,
    profiles: list[VoiceProfile],
    context: VoiceContext | None = None,
) -> str | None:
    """Set the segment's voice fields; the speaker ("self"/"other"), or None to leave it to
    the energy rule (no own profile and no sure match)."""
    context = context or VoiceContext()
    has_self = any(p.is_self for p in profiles)
    match = best_match(profiles, embedding, context.center)
    match_from, suggest_from, margin = voice_thresholds(context.center is not None)
    loud = (
        context.loud_from is not None
        and segment.audio_energy is not None
        and segment.audio_energy >= context.loud_from
    )
    if match is not None and match.similarity >= suggest_from:
        segment.voice_similarity = round(match.similarity, 4)
        if (
            match.similarity >= match_from
            and match.lead >= margin
            # Loud is most likely the user, near the microphone: someone else only asked
            and (match.profile.is_self or not loud)
        ):
            segment.voice_profile_id = match.profile.id
            segment.voice_match = "auto"
            return "self" if match.profile.is_self else "other"
        if not match.profile.is_self:
            segment.voice_profile_id = match.profile.id
            segment.voice_match = "suggested"
    if not has_self:
        return None
    # No voice is sure: loud is the user's own, near the microphone
    return "self" if loud else "other"


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
            .where(Segment.recorded_at >= started_at - SEGMENT_REACH)
            .where(Segment.recorded_at <= ended_at)
        )
    ).scalars().all()
    rows = [s for s in rows if _read_during(s, started_at, ended_at)]
    pending = [s for s in rows if s.transcription_status in ("pending", "processing")]
    samples = [s for s in rows if s.voice_embedding is not None]
    # The wearable sends a segment once it ends, up to 25 s after its first word
    if (pending or not samples) and now < ended_at + ENROLL_GRACE:
        return Enrollment("waiting")
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
        label_speaker(segment, "self")
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
    turn: int | None = None,
) -> Assignment:
    """The user says whose voice a segment is: "me", a person of theirs, or a new name.
    With `turn`, whose voice that one turn of the segment is (several people spoke in it):
    the voice is learned from that turn alone, not from the mix."""
    user_id = segment.user_id
    turns: list[dict] = []
    if turn is None:
        embedding = (
            await db.execute(select(Segment.voice_embedding).where(Segment.id == segment.id))
        ).scalar_one_or_none()
    else:
        turns = list((segment.transcription.turns if segment.transcription else None) or [])
        if not 0 <= turn < len(turns):
            raise LookupError("turn not found")
        embedding = turns[turn].get("embedding")

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
        # Theirs, or one named so before they were in People
        query = query.where(~VoiceProfile.is_self).where(or_(
            VoiceProfile.person_id == person.id,
            func.lower(VoiceProfile.name) == name.lower(),
        ))
    else:
        query = query.where(
            ~VoiceProfile.is_self, func.lower(VoiceProfile.name) == name.lower()
        )
    profile = (await db.execute(query.limit(1))).scalar_one_or_none()

    if profile is None and embedding is None:
        raise ValueError("this segment has no voice fingerprint to start a profile from")
    if not is_self and person is None:
        # Naming a voice is the user saving that person: in People from now on
        # (as the voice was already named, when it was)
        person = Entity(
            user_id=user_id, entity_type="person", metadata_={},
            name=profile.name if profile is not None else name,
        )
        db.add(person)
        await db.flush()
    if profile is not None and person is not None and profile.person_id is None:
        profile.person_id = person.id

    if profile is None:
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

    if turn is None:
        segment.voice_profile_id = profile.id
        segment.voice_match = "confirmed"
        segment.voice_similarity = None
        label_speaker(segment, "self" if is_self else "other")
    else:
        turns[turn] = {
            **turns[turn],
            "speaker": "self" if is_self else "other",
            "profile_id": str(profile.id),
            "group": None,
            "confirmed": True,
        }
        segment.transcription.turns = turns  # a new list: the JSON change is seen

    relabelled = 0
    if segment.conversation_id is not None:
        relabelled = await _relabel_conversation(db, segment, profile)
        relabelled += await _relabel_turns(db, segment.conversation_id, profile)
    await db.commit()
    return Assignment(profile, relabelled, embedding is not None)


async def _relabel_turns(
    db: AsyncSession, conversation_id: uuid.UUID, profile: VoiceProfile
) -> int:
    """The conversation's turns with this voice: those nearer to it than to any other
    known voice, by the margin (through the pendant every voice is near every other);
    never a turn the user named."""
    profiles = await list_profiles(db, profile.user_id)
    center = (await voice_context(db, profile.user_id)).center
    match_from, _, margin = voice_thresholds(center is not None)
    transcriptions = (
        await db.execute(
            select(Transcription)
            .join(Segment, Segment.id == Transcription.segment_id)
            .where(Segment.conversation_id == conversation_id)
            .where(Transcription.turns.isnot(None))
        )
    ).scalars().all()
    count = 0
    for transcription in transcriptions:
        if not transcription.turns:  # a JSON null written before none_as_null
            continue
        turns = []
        for turn in transcription.turns:
            match = (
                best_match(profiles, turn["embedding"], center)
                if turn.get("embedding") and not turn.get("confirmed")
                else None
            )
            if (
                match is not None
                and match.profile.id == profile.id
                and match.similarity >= match_from
                and match.lead >= margin
                and turn.get("profile_id") != str(profile.id)
            ):
                turn = {
                    **turn,
                    "speaker": "self" if profile.is_self else "other",
                    "profile_id": str(profile.id),
                    "group": None,
                }
                count += 1
            turns.append(turn)
        if turns != transcription.turns:
            transcription.turns = turns
    return count


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
    # Nearest to this voice, and clearly nearer than to any other: near this voice alone
    # took a whole conversation, every voice through the pendant being near every other
    profiles = await list_profiles(db, profile.user_id)
    center = (await voice_context(db, profile.user_id)).center
    match_from, _, margin = voice_thresholds(center is not None)
    count = 0
    for segment in others:
        match = best_match(profiles, segment.voice_embedding, center)
        if (
            match is not None
            and match.profile.id == profile.id
            and match.similarity >= match_from
            and match.lead >= margin
        ):
            segment.voice_profile_id = profile.id
            segment.voice_match = "auto"
            segment.voice_similarity = round(match.similarity, 4)
            label_speaker(segment, "self" if profile.is_self else "other")
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
