# Firmware updates over Bluetooth, through the app

Updating the wearable meant plugging it into the Mac. It now updates over the same BLE link that
carries the audio: the Mac publishes a build to the Echo server, the app offers it, and the
wearable writes it next to the running firmware and switches only if it is intact and works.

## Decision

- **Where the image comes from**: `make firmware-release` builds the firmware and publishes it
  inside the server's api container (`app/cli/firmware.py`; one image per version, ESP32-S3
  images only). There is no upload endpoint: any account can call the API, and registration is
  open (changed on 16/10; it was `POST /api/firmware`). The app asks
  `GET /api/firmware/latest` at most once an hour and compares it with the version the wearable
  reports in DEVICE_INFO, now sent after every READY.
- **Started by the user**: Settings → Device shows "Update Echo" (and Today a one-time tip). The
  update never starts by itself: the microphone pauses for about a minute.
- **Protocol 4**: `OTA_BEGIN` (size and SHA-256) and `OTA_ABORT` on the control characteristic,
  `OTA_STATUS` back; the image goes to a new encrypted-write characteristic as
  `[offset, bytes]`, one write with response at a time. The wearable writes each chunk to the
  inactive app slot (`default_8MB.csv` has two of 3.3 MB) before acknowledging it, so the app
  never gets ahead of the flash.
- **Before**: the wearable must hold no audio or photo (a restart loses RAM); the app waits for
  them to be sent. With a known battery level under 20 % the wearable refuses.
- **Checks**: the app checks the download against the server's SHA-256; the wearable hashes what
  it writes and compares it with the SHA-256 in `OTA_BEGIN`; `esp_ota_end` validates the image.
  Anything else leaves the running firmware untouched.
- **Signed (protocol 6, firmware 0.8.0, 29/10)**: the SHA-256 alone came from whoever sent the
  image, so the server or the paired phone could install any firmware on a device with a
  microphone and a camera. `OTA_BEGIN` now also carries the release key's ECDSA P-256 signature
  of the SHA-256 (raw r||s, 64 bytes); the wearable checks it with micro-ecc against the public
  key built into it (`src/ota_public_key.h`) before writing anything, and refuses with
  `OTA_ERROR_BAD_SIGNATURE` (10). The private key is made once by
  `scripts/firmware-signing-key.sh` and never committed (`firmware/signing/`); the release script
  signs with `openssl dgst -sha256 -sign`, the server stores the signature
  (`firmware_releases.signature`, migration 030) and the app passes it on. A wearable on
  protocol 4–5 still gets the unsigned frame, once, to move to 0.8.0. Kept off the server, the
  key also stops whoever controls the server; on the server, it still stops the database, the
  API and the network in between. Not covered: an older signed image (no anti-rollback), and
  Secure Boot, which would also check at every boot but cannot be undone once burnt.
- **Rollback**: the bootloader runs a new firmware on trial (`verifyRollbackLater`). It is kept
  once the app talks to it (connected, bonded, time set). If it crashes, fails to start, or the
  app does not reach it within 5 minutes, the previous firmware comes back. "The app can reach
  it" is the property that matters: a firmware the app reaches can always be updated again.

## Considered Options

- **Image bundled in the app**: simpler, no server, but every firmware would need an app build
  and a reinstall.
- **Wi-Fi OTA from the wearable**: faster, but the wearable has no Wi-Fi configuration since
  ADR 0006 and would need credentials and a server address.
- **Write without response**: faster, but chunks could overrun NimBLE's buffers while the host
  task writes flash, so the transfer would need its own windowing and retransmission.

## Consequences

- Up to firmware 0.7 the image was not signed and only the BLE bond (one phone, encrypted
  writes) kept others out. From 0.8.0 it is signed (see "Signed" above); secure boot and flash
  encryption are still off, so someone with the device in hand can flash it over the cable.
- The first firmware with updates over Bluetooth (0.5.0, protocol 4) goes over the cable; the
  app says so for an older wearable.
- About 600 KB at one acknowledged write per connection event: roughly a minute on iOS.
