"""Publishing a wearable firmware: only on the server (`make firmware-release`), never over HTTP.

Registration is open, so any account can call the API: an upload endpoint would let anyone
push a firmware to every wearable. The CLI runs inside the api container instead.
"""

import hashlib
import re

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.firmware_release import FirmwareRelease

# One app slot of the wearable's partition table (default_8MB.csv: app0/app1)
MAX_IMAGE_BYTES = 0x330000
ESP_IMAGE_MAGIC = 0xE9
ESP32_S3_CHIP_ID = 9
VERSION_PATTERN = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")


class InvalidFirmwareError(ValueError):
    """The image or the version cannot be published; the message says why."""


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


async def publish_release(
    db: AsyncSession, version: str, notes: str | None, data: bytes
) -> tuple[FirmwareRelease, bool]:
    """The release, and whether it is new. The same image again is fine; another is not."""
    if parse_version(version) is None:
        raise InvalidFirmwareError("Version must be major.minor.patch, each 0-255")
    if len(data) > MAX_IMAGE_BYTES:
        raise InvalidFirmwareError("Image larger than the wearable's app slot")
    if not is_esp32_s3_image(data):
        raise InvalidFirmwareError("Not an ESP32-S3 firmware image")

    sha256 = hashlib.sha256(data).hexdigest()
    existing = (
        await db.execute(select(FirmwareRelease).where(FirmwareRelease.version == version))
    ).scalar_one_or_none()
    if existing is not None:
        if existing.sha256 != sha256:
            raise InvalidFirmwareError(
                f"Version {version} is already published with another image: "
                "raise FIRMWARE_VERSION in firmware/src/config.h"
            )
        return existing, False

    release = FirmwareRelease(
        version=version, size_bytes=len(data), sha256=sha256, notes=notes or None, image=data
    )
    db.add(release)
    await db.commit()
    return release, True
