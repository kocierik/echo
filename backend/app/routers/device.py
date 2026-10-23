"""The phone's side of Echo: commands to run, their results, and the iPhone's apps.

- `GET /device/commands`: long poll for TAKE_PHOTO (relayed to the wearable) and
  `phone_action` (run on the iPhone), see services/device_commands.py;
- `POST /device/commands/{id}/result`: what a `phone_action` did, or the place a
  `get_location` read;
- `PUT /device/phone-apps`: which of the iPhone's Reminders and Calendar Echo may use
  (actions/phone_provider.py).
"""

import re
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from pydantic import BaseModel, Field

from app.actions.phone_provider import record_phone_result, set_phone_apps
from app.core.auth import get_current_user_id
from app.services.device_commands import take_device_commands

router = APIRouter(prefix="/device", tags=["device"])

MAX_WAIT_S = 25
COMMAND_ID = re.compile(r"^[0-9a-f]{32}$")


@router.get("/commands")
async def device_commands(
    request: Request,
    wait: int = Query(default=0, ge=0, le=MAX_WAIT_S),
    user_id: uuid.UUID = Depends(get_current_user_id),
):
    """Commands for the phone and the wearable, waiting up to `wait` seconds for one.

    Each is handed out once: the app relays a TAKE_PHOTO to the wearable (then uploads the
    photo or reports the failure) and runs a `phone_action` (then posts its result).
    """
    commands = await take_device_commands(request.app.state.redis, user_id, wait)
    return {"commands": commands}


class PhoneActionResult(BaseModel):
    ok: bool
    data: dict | list | str | None = None
    error: str | None = Field(default=None, max_length=500)


@router.post("/commands/{command_id}/result", status_code=status.HTTP_204_NO_CONTENT)
async def phone_action_result(
    command_id: str,
    body: PhoneActionResult,
    request: Request,
    user_id: uuid.UUID = Depends(get_current_user_id),
):
    """What the iPhone did for a `phone_action`; the waiting request reads it."""
    if not COMMAND_ID.match(command_id) or not await record_phone_result(
        request.app.state.redis, user_id, command_id, body.model_dump()
    ):
        raise HTTPException(status_code=404, detail="Unknown or expired command")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


class PhoneApps(BaseModel):
    reminders: bool = False
    calendar: bool = False


@router.put("/phone-apps", response_model=PhoneApps)
async def put_phone_apps(
    body: PhoneApps,
    request: Request,
    user_id: uuid.UUID = Depends(get_current_user_id),
):
    """The app says which of the iPhone's apps are on (on every wake, and on a change)."""
    apps = [
        slug
        for slug, on in (("applereminders", body.reminders), ("applecalendar", body.calendar))
        if on
    ]
    await set_phone_apps(request.app.state.redis, user_id, apps)
    return body
