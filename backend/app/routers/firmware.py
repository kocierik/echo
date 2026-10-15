"""Wearable firmware: published from the Mac, offered to the app, sent over BLE by the app.

`make firmware-release` builds the firmware and uploads it here (POST /firmware). The app
asks for the latest version (GET /firmware/latest), compares it with the one the wearable
reports and, when the user asks, downloads the image and sends it to the wearable, which
checks it against the SHA-256 before restarting into it.
"""

import hashlib
import re
from datetime import datetime

from fastapi import APIRouter, Depends, File, Form, HTTPException, Response, UploadFile, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import undefer

from app.core.auth import get_current_user_id
from app.core.database import get_db
from app.models.firmware_release import FirmwareRelease

router = APIRouter(prefix="/firmware", tags=["firmware"])

# One app slot of the wearable's partition table (default_8MB.csv: app0/app1)
MAX_IMAGE_BYTES = 0x330000
ESP_IMAGE_MAGIC = 0xE9
ESP32_S3_CHIP_ID = 9
VERSION_PATTERN = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")


class FirmwareOut(BaseModel):
    version: str
    size_bytes: int
    sha256: str
    notes: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


class LatestFirmware(BaseModel):
    firmware: FirmwareOut | None


def parse_version(version: str) -> tuple[int, int, int] | None:
    """(major, minor, patch), each a byte as the wearable reports it; None otherwise."""
    match = VERSION_PATTERN.match(version)
    if match is None:
        return None
    parts = tuple(int(part) for part in match.groups())
    return parts if all(part <= 255 for part in parts) else None  # type: ignore[return-value]


def is_esp32_s3_image(data: bytes) -> bool:
    """The app image header: magic byte, and the chip id at offset 12 (little endian)."""
    return (
        len(data) > 24
        and data[0] == ESP_IMAGE_MAGIC
        and int.from_bytes(data[12:14], "little") == ESP32_S3_CHIP_ID
    )


@router.post("", response_model=FirmwareOut, status_code=status.HTTP_201_CREATED)
async def publish_firmware(
    response: Response,
    version: str = Form(..., description="As in firmware/src/config.h, e.g. 0.5.0"),
    notes: str | None = Form(default=None, max_length=500),
    image: UploadFile = File(..., description="firmware.bin built by PlatformIO"),
    _user_id=Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Publish a version. The same image again is fine; another image for it is not."""
    if parse_version(version) is None:
        raise HTTPException(status_code=422, detail="Version must be major.minor.patch, each 0-255")
    data = await image.read(MAX_IMAGE_BYTES + 1)
    if len(data) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="Image larger than the wearable's app slot")
    if not is_esp32_s3_image(data):
        raise HTTPException(status_code=400, detail="Not an ESP32-S3 firmware image")

    sha256 = hashlib.sha256(data).hexdigest()
    existing = (
        await db.execute(select(FirmwareRelease).where(FirmwareRelease.version == version))
    ).scalar_one_or_none()
    if existing is not None:
        if existing.sha256 != sha256:
            raise HTTPException(
                status_code=409,
                detail=f"Version {version} is already published with another image: "
                "raise FIRMWARE_VERSION in firmware/src/config.h",
            )
        response.status_code = status.HTTP_200_OK
        return existing

    release = FirmwareRelease(
        version=version, size_bytes=len(data), sha256=sha256, notes=notes or None, image=data
    )
    db.add(release)
    await db.commit()
    return release


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
