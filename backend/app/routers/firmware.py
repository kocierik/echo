"""Wearable firmware: published on the server, offered to the app, sent over BLE by the app.

`make firmware-release` builds the firmware and publishes it inside the server
(app/cli/firmware.py): there is no upload endpoint, since any account can call the API. The
app asks for the latest version (GET /firmware/latest), compares it with the one the wearable
reports and, when the user asks, downloads the image and sends it to the wearable, which
checks the release key's signature and the SHA-256 before restarting into it.
"""

from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import undefer

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.firmware_release import FirmwareRelease
from app.services.firmware import parse_version

router = APIRouter(prefix="/firmware", tags=["firmware"])


class FirmwareOut(BaseModel):
    version: str
    size_bytes: int
    sha256: str
    # The release key's signature, sent to the wearable with the SHA-256 (hex r||s)
    signature: str | None
    notes: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


class LatestFirmware(BaseModel):
    firmware: FirmwareOut | None


@router.get("/latest", response_model=LatestFirmware)
async def latest_firmware(
    _user_id=Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """The highest version published (by number, not by date); null when there is none."""
    releases = (await db.execute(select(FirmwareRelease))).scalars().all()
    newest = max(releases, key=lambda r: parse_version(r.version) or (0, 0, 0), default=None)
    return LatestFirmware(firmware=newest)


@router.get("/{version}/image")
async def firmware_image(
    version: str,
    _user_id=Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    release = (
        await db.execute(
            select(FirmwareRelease)
            .options(undefer(FirmwareRelease.image))
            .where(FirmwareRelease.version == version)
        )
    ).scalar_one_or_none()
    if release is None:
        raise HTTPException(status_code=404, detail="Firmware not found")
    return Response(
        content=release.image,
        media_type="application/octet-stream",
        headers={"X-Sha256": release.sha256},
    )
