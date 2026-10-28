"""Profile → WhatsApp: whether it can be linked, its state, linking with a pairing code
and unlinking. The bridge does the work (services/whatsapp_bridge.py)."""

import uuid

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, Field, field_validator

from app.actions.whatsapp_provider import forget_linked
from app.core.auth import get_current_user_id
from app.services import whatsapp_bridge
from app.services.whatsapp_bridge import BridgeError

router = APIRouter(prefix="/whatsapp", tags=["whatsapp"])


class WhatsAppOut(BaseModel):
    # False on a server without the bridge: the app shows nothing
    available: bool
    # "unlinked" | "linking" | "linked" | "unreachable"
    state: str
    phone: str | None = None


class LinkIn(BaseModel):
    # With the country code ("+39 333 1234567"); the bridge keeps the digits
    phone: str = Field(min_length=8, max_length=30)

    @field_validator("phone")
    @classmethod
    def _with_country_code(cls, value: str) -> str:
        # "333 1234567" would be read as another country's number, maybe a stranger's
        if not value.strip().startswith(("+", "00")):
            raise ValueError("the number must start with its country code (+39…)")
        return value


class LinkOut(BaseModel):
    # Typed in WhatsApp → Linked devices → Link with phone number instead
    code: str


def _bridge():
    bridge = whatsapp_bridge.get_bridge()
    if bridge is None:
        raise HTTPException(status_code=404, detail="WhatsApp is not available on this server")
    return bridge


@router.get("", response_model=WhatsAppOut)
async def whatsapp_status(user_id: uuid.UUID = Depends(get_current_user_id)):
    bridge = whatsapp_bridge.get_bridge()
    if bridge is None:
        return WhatsAppOut(available=False, state="unlinked")
    try:
        found = await bridge.status(user_id)
    except BridgeError:
        return WhatsAppOut(available=True, state="unreachable")
    return WhatsAppOut(
        available=True, state=found.get("state", "unlinked"), phone=found.get("phone")
    )


@router.post("/link", response_model=LinkOut)
async def link_whatsapp(
    body: LinkIn, request: Request, user_id: uuid.UUID = Depends(get_current_user_id)
):
    try:
        code = await _bridge().link(user_id, body.phone)
    except BridgeError as exc:
        if exc.status == 409:
            raise HTTPException(status_code=409, detail="WhatsApp is already linked") from exc
        if exc.status == 400:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        if exc.status == 504:
            raise HTTPException(
                status_code=504, detail="WhatsApp did not answer in time. Try again."
            ) from exc
        raise HTTPException(status_code=502, detail="Could not reach WhatsApp") from exc
    await forget_linked(getattr(request.app.state, "redis", None), user_id)
    return LinkOut(code=code)


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
async def unlink_whatsapp(request: Request, user_id: uuid.UUID = Depends(get_current_user_id)):
    try:
        await _bridge().unlink(user_id)
    except BridgeError as exc:
        raise HTTPException(status_code=502, detail="Could not reach WhatsApp") from exc
    await forget_linked(getattr(request.app.state, "redis", None), user_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
