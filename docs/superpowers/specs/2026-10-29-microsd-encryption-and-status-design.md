# microSD: speech encrypted on the card, and the card in the app

Date: 2026-10-29. The user has a microSD card in the wearable and asked to "add microSD support".
Firmware 0.6.0 (24/10) already moves speech that does not fit in PSRAM to the card. The user then
chose both follow-ups: encrypt what is on the card, and show the card in the app ("procedi con
tutte e due"). Every decision below is the builder's call unless quoted.

## Intent

The card is removable: today anyone who takes it can listen to the conversations it holds until
they reach the phone. And the user cannot see whether the card is in use, how much room is left
or how much speech waits on it.

## Goals

- **Encrypted on the card.** Each segment's audio is written to the card encrypted with AES-256-CTR
  under a random per-record IV (16 bytes, kept in front of the data). The key is 32 random bytes
  made on the device the first time a card is used and kept in its NVS; it never leaves the device.
  The record header (length, CRC of the plain audio, durations) stays in clear, as it says nothing
  about what was said. A record that does not decrypt to its CRC (another device's card, a key
  lost to a full flash erase) is skipped and counted as lost, as a corrupt one is today.
- **Old records move over.** Records left in clear by 0.6.0 (`/echo/q`) are moved, encrypted, into
  the new folder (`/echo/s`) at boot, oldest first, and the old folder is emptied: nothing waiting is
  lost and nothing stays in clear.
- **The card in the app.** DEVICE_STATUS (protocol 5) says whether a card is in use, its size, its
  free space and how much speech waits on it. Profile → Echo shows a "microSD" row: "29.1 GB free of
  29.7 GB · 12 min waiting", or "No card" (only for firmware with protocol 5).
- Firmware 0.7.0. Older apps and firmware keep working: the app accepts protocols 2 to 5.

## Non-goals

- Protecting against someone who has the whole wearable (the key is in its flash; flash
  encryption on the ESP32-S3 is permanent and makes development and recovery hard).
- Photos on the card, a card the user can read on a computer, formatting the card from the app.

## Constraints

- The card is touched only from the main loop (no SD access from the Bluetooth task): the status
  uses values the log keeps up to date, never a fresh read of the card.
- Native tests (PlatformIO `native`) cover the log, the cipher's use and the protocol; the AES and
  the NVS key run only on the device (mbedtls, hardware AES), to be tried there by the user.
