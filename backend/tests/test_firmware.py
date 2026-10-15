"""Wearable firmware published from the Mac and offered to the app for an update over BLE."""

import hashlib

import pytest

from app.routers.firmware import MAX_IMAGE_BYTES, is_esp32_s3_image, parse_version


def esp32_s3_image(size: int = 4096, seed: int = 1) -> bytes:
    header = bytearray(24)
    header[0] = 0xE9
    header[12:14] = (9).to_bytes(2, "little")
    return bytes(header) + bytes((seed + i) % 256 for i in range(size - 24))


async def publish(client, auth_headers, version, data, notes=None):
    form = {"version": version}
    if notes:
        form["notes"] = notes
    return await client.post(
        "/api/firmware",
        headers=auth_headers,
        data=form,
        files={"image": ("firmware.bin", data, "application/octet-stream")},
    )


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
async def test_publish_then_the_app_finds_and_downloads_it(client, auth_headers):
    assert (await client.get("/api/firmware/latest", headers=auth_headers)).json() == {
        "firmware": None
    }
    data = esp32_s3_image()

    response = await publish(client, auth_headers, "0.5.0", data, notes="Firmware updates")
    assert response.status_code == 201
    assert response.json()["sha256"] == hashlib.sha256(data).hexdigest()

    latest = (await client.get("/api/firmware/latest", headers=auth_headers)).json()["firmware"]
    assert latest["version"] == "0.5.0"
    assert latest["size_bytes"] == len(data)
    assert latest["notes"] == "Firmware updates"

    image = await client.get("/api/firmware/0.5.0/image", headers=auth_headers)
    assert image.status_code == 200
    assert image.content == data
    assert image.headers["x-sha256"] == latest["sha256"]
    missing = await client.get("/api/firmware/9.9.9/image", headers=auth_headers)
    assert missing.status_code == 404


@pytest.mark.asyncio
async def test_latest_is_the_highest_version_not_the_last_published(client, auth_headers):
    await publish(client, auth_headers, "0.10.0", esp32_s3_image(seed=1))
    await publish(client, auth_headers, "0.9.3", esp32_s3_image(seed=2))

    latest = (await client.get("/api/firmware/latest", headers=auth_headers)).json()["firmware"]
    assert latest["version"] == "0.10.0"


@pytest.mark.asyncio
async def test_a_version_keeps_its_image(client, auth_headers):
    data = esp32_s3_image()
    assert (await publish(client, auth_headers, "0.5.0", data)).status_code == 201
    # The same build again (a retried upload) is fine
    assert (await publish(client, auth_headers, "0.5.0", data)).status_code == 200
    other = await publish(client, auth_headers, "0.5.0", esp32_s3_image(seed=7))
    assert other.status_code == 409
    assert "FIRMWARE_VERSION" in other.json()["detail"]


@pytest.mark.asyncio
async def test_bad_uploads_are_refused(client, auth_headers):
    assert (await publish(client, auth_headers, "five", esp32_s3_image())).status_code == 422
    assert (await publish(client, auth_headers, "0.5.0", b"\x00" * 4096)).status_code == 400
    too_large = esp32_s3_image(MAX_IMAGE_BYTES + 1)
    assert (await publish(client, auth_headers, "0.5.0", too_large)).status_code == 413


@pytest.mark.asyncio
async def test_firmware_needs_the_api_key(client):
    assert (await client.get("/api/firmware/latest")).status_code in (401, 403)
