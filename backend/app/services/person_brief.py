"""Who is in front of you: a known voice starts talking, the phone says what to know.

Run by the STT worker after a live segment's voice matched a named person with
confidence (`voice_match` "auto", never the "Marco?" suggestion, never the user's own
voice). The facts are the meeting briefing's (`_what_to_know`): with nothing to say,
nothing is sent. Otherwise a `person_brief` device command goes to the app, which shows it
as a notification at once (tapping opens the person); one the phone does not take within
COMMAND_TTL_S is dropped, a late "who is in front of you" being noise. Rules:

- at most once per person every PERSON_EVERY (a Redis key per person);
- not when a meeting briefing about them fires within NEAR_BRIEFING;
- the other notices' rules: the briefings switch, quiet hours, MAX_PER_DAY in total
  (services/notice_ledger.py).

No model call: the text is built from the stored facts.
"""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timezone import to_user_local_date
from app.models.entity import Entity
from app.models.segment import Segment
from app.models.voice_profile import VoiceProfile
from app.services.device_commands import push_device_command
from app.services.notice_ledger import briefing_near, briefings_on, count_on, record_sent
from app.services.notifications import (
    MAX_PER_DAY,
    _what_to_know,
    is_quiet,
    open_promises,
    open_waiting,
)
from app.services.voice_profiles import _person_named

PERSON_EVERY = timedelta(hours=4)
NEAR_BRIEFING = timedelta(hours=1)
COMMAND_TTL_S = 120
# Speech recorded longer ago (synced late from the wearable) is no longer in front of you
LIVE_WITHIN = timedelta(minutes=10)
COOLDOWN_KEY = "notify:person:{user_id}:{person_id}"


def confident_voice(segment: Segment, profiles: list[VoiceProfile]) -> VoiceProfile | None:
    """The named voice the segment surely is; None for the user's own or a suggestion."""
    if segment.voice_match != "auto" or segment.voice_profile_id is None:
        return None
    profile = next((p for p in profiles if p.id == segment.voice_profile_id), None)
    return None if profile is None or profile.is_self else profile


async def _person_of(db: AsyncSession, profile: VoiceProfile) -> Entity | None:
    if profile.person_id is not None:
        person = await db.get(Entity, profile.person_id)
        if person is not None and person.user_id == profile.user_id:
            return person
        return None
    return await _person_named(db, profile.user_id, profile.name)


def brief_text(person: Entity, facts: list[str]) -> tuple[str, str]:
    """Title and body: "Talking with Marco Rossi", "You promised: … · last talked …"."""
    body = " · ".join(facts)
    return f"Talking with {person.name}", body[:1].upper() + body[1:]


async def brief_who_is_talking(
    db: AsyncSession,
    redis,
    segment: Segment,
    profile: VoiceProfile,
    now: datetime | None = None,
) -> dict | None:
    """Send the brief about the person `profile` is, when the rules allow and there is
    something to say; the command sent, else None."""
    now = now or datetime.now(timezone.utc)
    user_id: uuid.UUID = segment.user_id
    if profile.is_self or now - segment.recorded_at > LIVE_WITHIN or is_quiet(now):
        return None
    if not await briefings_on(redis, user_id):
        return None
    person = await _person_of(db, profile)
    if person is None:
        return None
    target = f"person:{person.id}"
    if await briefing_near(redis, user_id, target, now, NEAR_BRIEFING):
        return None
    if await count_on(redis, user_id, to_user_local_date(now)) >= MAX_PER_DAY:
        return None
    facts = await _what_to_know(
        db, user_id, person, await open_promises(db, user_id), now,
        await open_waiting(db, user_id),
    )
    if not facts:
        return None
    # Last: a person with nothing to say now may have something in an hour
    cooldown = COOLDOWN_KEY.format(user_id=user_id, person_id=person.id)
    if not await redis.set(cooldown, "1", nx=True, ex=int(PERSON_EVERY.total_seconds())):
        return None
    title, body = brief_text(person, facts)
    command = {"type": "person_brief", "person_id": str(person.id), "title": title, "body": body}
    await push_device_command(redis, user_id, command, COMMAND_TTL_S)
    await record_sent(redis, user_id, f"{target}:{now.isoformat()}", "person", target, now)
    return command
