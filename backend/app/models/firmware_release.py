from sqlalchemy import Integer, LargeBinary, String, Text
from sqlalchemy.orm import Mapped, deferred, mapped_column

from app.models.base import Base, TimestampMixin, UUIDPrimaryKey


class FirmwareRelease(UUIDPrimaryKey, TimestampMixin, Base):
    """A wearable firmware published with `make firmware-release`, offered to the app.

    One per version for the whole server: the image is the same for every device. The app
    compares `version` with what the wearable reports, downloads the image and sends it over
    BLE; the wearable checks it against `sha256` before booting it.
    """

    __tablename__ = "firmware_releases"

    version: Mapped[str] = mapped_column(String(20), nullable=False, unique=True)
    size_bytes: Mapped[int] = mapped_column(Integer, nullable=False)
    sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    # The release key's ECDSA P-256 signature of the image, raw r||s in hex; none before
    # firmware 0.8.0, whose wearables refuse an image without it
    signature: Mapped[str | None] = mapped_column(String(128), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Loaded only when downloaded
    image: Mapped[bytes] = deferred(mapped_column(LargeBinary, nullable=False))
