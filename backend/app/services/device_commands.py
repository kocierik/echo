"""Commands for the phone and the wearable, picked up by the app's long poll.

The app polls `GET /device/commands` while it runs (the wearable keeps it awake through
the day). Each command is handed out once and carries its own `expires_at`: one the app
does not pick up in time is dropped. Kinds:

- `take_photo`: relayed to the wearable (services/photos.py);
- `phone_action`: run on the iPhone with EventKit (actions/phone_provider.py). Picking it
  up is remembered (DELIVERED_KEY): a call that gets no answer then may have run;
- `get_location`: the phone's place for a thing being saved (services/phone_location.py);
- `voice_update`: new answers in the thread with Echo (a spoken request or a photo was
  answered, a routine ran): the phone checks at once (`tell_phone_to_check`);
- `person_brief`: a known voice started talking, what to know about them, shown at once
  (services/person_brief.py).
"""

import json
import logging
import uuid
from datetime import datetime, timedelta, timezone

logger = logging.getLogger(__name__)

DEVICE_COMMANDS_KEY = "device:commands:{user_id}"
DELIVERED_KEY = "device:delivered:{command_id}"
DELIVERED_TTL_S = 300
# The list itself lives at least this long: each command expires on its own
LIST_TTL_S = 300


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


async def push_device_command(
    redis_client, user_id: uuid.UUID | str, command: dict, ttl_s: int
) -> None:
    """Queue `command` (a dict with a "type") for the app, valid for `ttl_s` seconds."""
    key = DEVICE_COMMANDS_KEY.format(user_id=user_id)
    expires_at = _utcnow() + timedelta(seconds=ttl_s)
    await redis_client.rpush(key, json.dumps({**command, "expires_at": expires_at.isoformat()}))
    await redis_client.expire(key, max(ttl_s, LIST_TTL_S))


async def take_device_commands(redis_client, user_id: uuid.UUID, wait_s: int) -> list[dict]:
    """Pending commands, waiting up to `wait_s` for the first one; expired ones dropped."""
    key = DEVICE_COMMANDS_KEY.format(user_id=user_id)
    raw: list = []
    if wait_s > 0:
        first = await redis_client.blpop([key], timeout=wait_s)
        if first is not None:
            raw.append(first[1])
    while (item := await redis_client.lpop(key)) is not None:
        raw.append(item)

    now = _utcnow()
    commands = []
    for item in raw:
        try:
            command = json.loads(item)
            expires_at = datetime.fromisoformat(command["expires_at"])
        except (ValueError, KeyError, TypeError):
            logger.warning("Dropping an invalid device command")
            continue
        if expires_at <= now:
            continue
        if isinstance(command.get("id"), str):
            await redis_client.set(
                DELIVERED_KEY.format(command_id=command["id"]), "1", ex=DELIVERED_TTL_S
            )
        commands.append(command)
    return commands


# An answer the phone did not come for in this long is found at its next check anyway
VOICE_UPDATE_TTL_S = 15 * 60


async def tell_phone_to_check(redis_client, user_id: uuid.UUID | str) -> None:
    """A new answer is in the thread with Echo: the phone is told to look now. Without it
    the phone looked only at its next upload or when the app was opened: after a spoken
    question, in silence, the answer waited there. Never raises."""
    try:
        await push_device_command(
            redis_client, user_id, {"type": "voice_update"}, VOICE_UPDATE_TTL_S
        )
    except Exception:
        logger.warning("Could not tell the phone to check its answers", exc_info=True)
