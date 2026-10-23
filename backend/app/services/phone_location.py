"""The phone's place, read only when the user asks to save something with it.

A save that asks for the place (the car, "salvami questo posto") pushes a `get_location`
device command; the app reads the position (asking for the permission the first time),
geocodes the address and posts it through `POST /device/commands/{id}/result`, as a
`phone_action` does. Nothing reads the position otherwise, and the place is kept only in
the thing saved.

When the phone cannot answer now (the app is in the background, where iOS and Android
give no position to an app allowed "while in use"), it says "background", tells the user
to open Echo and, opened soon enough, sends the place to the thing itself
(`PUT /api/saved/items/{id}/place`).
"""

import json
import logging
import math
import uuid
from dataclasses import dataclass

from redis.exceptions import RedisError

from app.actions.phone_provider import OWNER_KEY, RESULT_KEY, RESULT_TTL_S
from app.services.device_commands import DELIVERED_KEY, push_device_command

logger = logging.getLogger(__name__)

# The phone has this long to read the place (the design's 30 s); the save waits as long
LOCATION_WAIT_S = 30
# Why the place could not be read: the phone's own reasons and the server's
REASONS = ("no_phone", "timeout", "background", "denied", "unavailable")
MAX_ADDRESS = 300


@dataclass
class PlaceAnswer:
    """The place ({"latitude", "longitude", "accuracy_m", "address"}) or why not."""

    place: dict | None = None
    error: str | None = None


def valid_place(data) -> dict | None:
    """The place as kept, or None when the coordinates are missing or out of range."""
    if not isinstance(data, dict):
        return None
    try:
        latitude = float(data["latitude"])
        longitude = float(data["longitude"])
    except (KeyError, TypeError, ValueError):
        return None
    if not (math.isfinite(latitude) and math.isfinite(longitude)):
        return None
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        return None
    accuracy = data.get("accuracy_m")
    try:
        accuracy = float(accuracy) if accuracy is not None else None
    except (TypeError, ValueError):
        accuracy = None
    address = data.get("address")
    address = " ".join(address.split())[:MAX_ADDRESS] if isinstance(address, str) else None
    return {
        "latitude": latitude,
        "longitude": longitude,
        "accuracy_m": accuracy,
        "address": address or None,
    }


async def ask_phone_location(
    redis_client,
    user_id: uuid.UUID | str,
    *,
    item_id: str | None = None,
    wait_s: float = LOCATION_WAIT_S,
) -> PlaceAnswer:
    """Ask the phone where it is, waiting up to `wait_s`. `item_id`: the thing the place
    is for, so a phone that can answer only later sends it there."""
    if redis_client is None:
        return PlaceAnswer(error="no_phone")
    command_id = uuid.uuid4().hex
    try:
        await redis_client.set(
            OWNER_KEY.format(command_id=command_id), str(user_id), ex=RESULT_TTL_S
        )
        await push_device_command(
            redis_client,
            user_id,
            {"type": "get_location", "id": command_id, "item_id": item_id},
            # Picked up late, it still has a third of the wait to read the place
            max(1, math.ceil(wait_s * 2 / 3)),
        )
        answer = await redis_client.blpop(
            [RESULT_KEY.format(command_id=command_id)], timeout=wait_s
        )
        delivered = answer is None and await redis_client.get(
            DELIVERED_KEY.format(command_id=command_id)
        )
    except RedisError:
        logger.warning("Could not ask the phone for its place", exc_info=True)
        return PlaceAnswer(error="no_phone")
    if answer is None:
        return PlaceAnswer(error="timeout" if delivered else "no_phone")
    try:
        result = json.loads(answer[1])
    except (TypeError, ValueError):
        return PlaceAnswer(error="unavailable")
    if result.get("ok") is not True:
        error = result.get("error")
        return PlaceAnswer(error=error if error in REASONS else "unavailable")
    place = valid_place(result.get("data"))
    return PlaceAnswer(place=place) if place else PlaceAnswer(error="unavailable")
