"""Wearable firmware published on the server and offered to the app for an update over BLE."""

import hashlib

import pytest

from app.services.firmware import (
    MAX_IMAGE_BYTES,
    InvalidFirmwareError,
    is_esp32_s3_image,
    parse_version,
    publish_release,
    raw_signature,
)

# `openssl dgst -sha256 -sign` over "echo firmware" (DER), and the same as raw r||s: what the
# wearable checks (firmware/test/test_ota). Its s has a leading zero byte in DER
OPENSSL_DER = bytes.fromhex(
    "3045022034575f6dfcd8775b61b0a722b9a85f2289e795c2bbcb14cbfe396d80f68430f9022100d97051d4"
    "885477b8fc44470be5b9d63d682cc55f1beefdec567398e9597bf0ca"
)
OPENSSL_RAW = (
    "34575f6dfcd8775b61b0a722b9a85f2289e795c2bbcb14cbfe396d80f68430f9"
    "d97051d4885477b8fc44470be5b9d63d682cc55f1beefdec567398e9597bf0ca"
)


def esp32_s3_image(size: int = 4096, seed: int = 1) -> bytes:
    header = bytearray(24)
    header[0] = 0xE9
    header[12:14] = (9).to_bytes(2, "little")
    return bytes(header) + bytes((seed + i) % 256 for i in range(size - 24))


async def publish(db_session, version, data, notes=None, signature=OPENSSL_DER):
    """As `make firmware-release` does, inside the server (not over HTTP)."""
    return await publish_release(db_session, version, notes, data, signature)


def test_versions_are_three_bytes_as_the_wearable_reports_them():
    assert parse_version("0.5.0") == (0, 5, 0)
    assert parse_version("1.10.255") == (1, 10, 255)
    assert parse_version("1.256.0") is None
    assert parse_version("1.2") is None
    assert parse_version("v1.2.3") is None


def test_only_esp32_s3_images_are_accepted():
    assert is_esp32_s3_image(esp32_s3_image())
    esp32 = bytearray(esp32_s3_image())
    esp32[12] = 0  # an ESP32 (classic) image
    assert not is_esp32_s3_image(bytes(esp32))
    assert not is_esp32_s3_image(b"\x00" * 100)


@pytest.mark.asyncio
async def test_publish_then_the_app_finds_and_downloads_it(client, auth_headers, db_session):
    assert (await client.get("/api/firmware/latest", headers=auth_headers)).json() == {
        "firmware": None
    }
    data = esp32_s3_image()

    release, created = await publish(db_session, "0.5.0", data, notes="Firmware updates")
    assert created
    assert release.sha256 == hashlib.sha256(data).hexdigest()

    latest = (await client.get("/api/firmware/latest", headers=auth_headers)).json()["firmware"]
    assert latest["version"] == "0.5.0"
    assert latest["size_bytes"] == len(data)
    assert latest["notes"] == "Firmware updates"

    # The release key's signature, for the wearable to check
    assert latest["signature"] == OPENSSL_RAW

    image = await client.get("/api/firmware/0.5.0/image", headers=auth_headers)
    assert image.status_code == 200
    assert image.content == data
    assert image.headers["x-sha256"] == latest["sha256"]
    missing = await client.get("/api/firmware/9.9.9/image", headers=auth_headers)
    assert missing.status_code == 404


@pytest.mark.asyncio
async def test_latest_is_the_highest_version_not_the_last_published(
    client, auth_headers, db_session
):
    await publish(db_session, "0.10.0", esp32_s3_image(seed=1))
    await publish(db_session, "0.9.3", esp32_s3_image(seed=2))

    latest = (await client.get("/api/firmware/latest", headers=auth_headers)).json()["firmware"]
    assert latest["version"] == "0.10.0"


@pytest.mark.asyncio
async def test_a_version_keeps_its_image(db_session):
    data = esp32_s3_image()
    assert (await publish(db_session, "0.5.0", data))[1] is True
    # The same build again (a retried release) is fine
    assert (await publish(db_session, "0.5.0", data))[1] is False
    with pytest.raises(InvalidFirmwareError, match="FIRMWARE_VERSION"):
        await publish(db_session, "0.5.0", esp32_s3_image(seed=7))


@pytest.mark.asyncio
async def test_bad_images_are_refused(db_session):
    with pytest.raises(InvalidFirmwareError, match="major.minor.patch"):
        await publish(db_session, "five", esp32_s3_image())
    with pytest.raises(InvalidFirmwareError, match="ESP32-S3"):
        await publish(db_session, "0.5.0", b"\x00" * 4096)
    with pytest.raises(InvalidFirmwareError, match="app slot"):
        await publish(db_session, "0.5.0", esp32_s3_image(MAX_IMAGE_BYTES + 1))


def test_an_openssl_signature_becomes_the_raw_one_the_wearable_checks():
    assert raw_signature(OPENSSL_DER).hex() == OPENSSL_RAW
    with pytest.raises(InvalidFirmwareError, match="signature"):
        raw_signature(b"not a signature")
    with pytest.raises(InvalidFirmwareError, match="signature"):
        raw_signature(OPENSSL_DER[:-1])


@pytest.mark.asyncio
async def test_an_unsigned_image_is_refused(db_session):
    with pytest.raises(InvalidFirmwareError, match="signature"):
        await publish(db_session, "0.8.0", esp32_s3_image(), signature=b"")


@pytest.mark.asyncio
async def test_no_account_can_publish_over_http(client, auth_headers):
    # Registration is open: an account must not be able to push firmware to every wearable
    response = await client.post(
        "/api/firmware",
        headers=auth_headers,
        data={"version": "9.9.9"},
        files={"image": ("firmware.bin", esp32_s3_image(), "application/octet-stream")},
    )
    assert response.status_code in (404, 405)
    latest = (await client.get("/api/firmware/latest", headers=auth_headers)).json()
    assert latest == {"firmware": None}


@pytest.mark.asyncio
async def test_firmware_needs_the_api_key(client):
    assert (await client.get("/api/firmware/latest")).status_code in (401, 403)
