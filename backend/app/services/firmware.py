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


def raw_signature(der: bytes) -> bytes:
    """The release key's signature as `openssl dgst -sign` gives it (DER), as the raw r||s
    the wearable checks (firmware/src/ota_signature.h): 32 bytes each."""
    invalid = InvalidFirmwareError("Not an ECDSA P-256 signature")

    def integer(at: int) -> tuple[bytes, int]:
        if at + 2 > len(der) or der[at] != 0x02:
            raise invalid
        end = at + 2 + der[at + 1]
        value = der[at + 2:end].lstrip(bytes(1))
        if end > len(der) or len(value) > 32:
            raise invalid
        return value.rjust(32, bytes(1)), end

    if len(der) < 8 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise invalid
    r, at = integer(2)
    s, at = integer(at)
    if at != len(der):
        raise invalid
    return r + s


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
    db: AsyncSession, version: str, notes: str | None, data: bytes, signature_der: bytes
) -> tuple[FirmwareRelease, bool]:
    """The release, and whether it is new. The same image again is fine; another is not.
    `signature_der`: the release key's signature of the image (scripts/firmware-release.sh);
    the wearable refuses an image without it."""
    if parse_version(version) is None:
        raise InvalidFirmwareError("Version must be major.minor.patch, each 0-255")
    if len(data) > MAX_IMAGE_BYTES:
        raise InvalidFirmwareError("Image larger than the wearable's app slot")
    if not is_esp32_s3_image(data):
        raise InvalidFirmwareError("Not an ESP32-S3 firmware image")
    signature = raw_signature(signature_der).hex()

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
        version=version, size_bytes=len(data), sha256=sha256, signature=signature,
        notes=notes or None, image=data,
    )
    db.add(release)
    await db.commit()
    return release, True
