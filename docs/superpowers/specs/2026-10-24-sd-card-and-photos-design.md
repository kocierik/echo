# microSD and better photos — Design

Date: 2026-10-24. Status: approved by the user in chat (24/10: points 1, 2 and 3).
Hardware: XIAO ESP32-S3 Sense with the OV3660 (3 MP) and a microSD card (FAT32, up to 32 GB — Seeed
wiki). The SD's chip select is GPIO21, the same pin as the user LED.

## Intent

Today Echo keeps about 13 minutes of speech in PSRAM when the phone is away, then drops the oldest; a
day without the phone loses almost everything. Photos are 1024×768 so they cross Bluetooth in a few
seconds, and the user finds them poor. With an SD card Echo can keep hours of speech and full-size
photos, and send them when it can.

## Goals

1. **No speech lost while the card has room**: when the PSRAM queue has no room for a new segment, its
   oldest segment moves to the SD instead of being dropped. Upload order stays oldest first: segments on
   the SD (older) go before those in PSRAM. Without a card, or with a card that fails, Echo behaves as
   today (drops the oldest, counts it).
2. **Sharper photos now**: the photo for the answer at 1600×1200 (UXGA) instead of 1024×768, with the
   PSRAM slot and the server limit raised to fit.
3. **Full-size photos with the card**: after the answer's photo, a second full-resolution shot
   (2048×1536 on the OV3660) is written to the SD and sent later, in the background, behind the speech;
   the server keeps it as the photo's original (shown when the photo is opened, read again on request).
4. **The LED and the card**: with a card mounted, the firmware never drives GPIO21 (it would disturb the
   card); the indicators fall back to none. Without a card, the LED works as today.
5. **Seen in the app**: Profile → Echo shows "SD card: 31.2 GB free" or "No SD card"; the
   "N min of speech to sync" line counts the SD backlog too.

## Non-goals

- Recording to the SD by default when the phone is near (the phone path stays the fast one).
- A file browser or export from the SD; video; Wi-Fi uploads from the wearable.
- exFAT or cards above 32 GB (the Sense supports up to 32 GB, FAT32).

## Anti-goals

- Corrupting the queue on a power cut: a half-written record is detected and skipped, never uploaded
  broken.
- Blocking audio capture while the SD writes: SD work runs off the audio path.
- Wearing the card out with tiny writes: segments are appended to large log files.

## Constraints

- Firmware PlatformIO/Arduino on the XIAO ESP32-S3; native unit tests (`pio test -e native`) for the
  logic; the BLE protocol keeps working with apps that do not know the new photo original (protocol
  version bump, old apps ignore it).
- Backend and app changes for the photo original and the SD status; English UI copy.

## Calls made by Claude (check these)

- **SD queue = append-only log files** of 4 MB (`/echo/q/NNNNNNNN.log`), records `[segment header + data]`
  with the existing data CRC; a small `/echo/q/head` file keeps the read position (file + offset). A
  file is deleted once fully sent. Card full: the oldest log file is dropped (the loss is counted and
  reported, as today).
- **One queue interface** for the transport (`peek` / `dequeue`): it reads the SD head first, staged
  in RAM one segment at a time, then the PSRAM queue.
- **Spill only when PSRAM is full** (not on every segment), so with the phone near the card is idle.
- **Photos**: UXGA, JPEG quality 12 for the answer; the original at QXGA, quality 10, only with a card.
- **SD on SPI**: CS GPIO21, SCK GPIO7, MISO GPIO8, MOSI GPIO9 (the XIAO's default SPI pins).

## Left to the builder

- How the full-size photo is sent (a new transfer kind on the existing photo channel, resumable) and
  how the server attaches it to the photo.
- The SD write task and its priority; what the transport reports while the backlog is on the card.
- Tests on the hardware: speech kept across a long absence of the phone, a power cut during a write,
  the card removed while running, photo sizes and transfer times.
