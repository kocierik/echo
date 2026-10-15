# Camera photos on request, kept in the database only

Echo's wearable (XIAO ESP32-S3 Sense) takes a photo only when asked: by voice ("Echo, what is
this?", "Echo, fai una foto") or with the camera button in the app's Ask tab. The photo goes over
BLE to the phone and from there to the backend, which stores the JPEG in Postgres; the wearable
keeps it in RAM only until the upload is confirmed. A vision model answers the question in the chat
and describes the photo for memory, so it can be found later ("what was on the whiteboard on
Monday?").

## Flow

1. Voice: the intent check (the same single LLM call as for apps) gets a camera option for voice
   requests only and routes the request to `photo`. The voice worker stores a photo request and
   queues TAKE_PHOTO for the user in Redis. The app button creates the request itself
   (`POST /api/photos`) and sends TAKE_PHOTO directly.
2. The app long-polls `GET /api/device/commands` while it runs and relays TAKE_PHOTO over BLE
   (protocol 3).
3. The firmware takes the photo in a camera task on core 0 (sensor started for the photo and
   stopped after it) and sends it before any audio: PHOTO_START, then the usual metadata, data,
   ACK windows and UPLOAD_OK. It answers PHOTO_FAILED when muted, busy, without a camera or when
   the capture fails.
4. The app uploads the JPEG (`PUT /api/photos/{id}/image`, idempotent) on any network, then sends
   UPLOAD_OK; a failure is reported (`POST /api/photos/{id}/failure`) and told in the chat.
5. The photos worker asks the vision model for an answer (chat), a description (memory chunk with
   `photo_id`, kept by transcript reanalysis) and a title (for a photo taken outside a
   conversation, which gets its own).

Since 15/10/2026 the description also goes through the same entity extraction as transcripts
(a whiteboard with "giovedì ore 15" becomes an event, marked with its `photo_id`), and a business
card or badge becomes a person in People with role, company, email and phone. That part is best
effort, in a savepoint: a failure never loses the answer. Transcript reanalysis keeps the entities
photos produced. Photos show in the conversation (summary, and in the transcript where they were
taken) and Memories counts them.

## Considered Options

- **Photos on the wearable's flash or an SD card**: rejected; the user wants nothing kept on the
  hardware, and RAM-only also means a lost device holds no photos.
- **Freeing the photo as soon as the phone has it**: rejected; iOS may suspend the app before the
  upload. The photo stays in RAM until UPLOAD_OK, as audio does.
- **Images on disk like audio**: rejected for now; a photo is ~50-150 KB and belongs to a chat and a
  conversation, so the database row (deleted with either) is simpler. Backups grow accordingly.
- **Periodic photos**: not built; on-request only, for battery, heat and the people around. The LED
  lights while a photo is taken, and muting also drops a photo waiting to be taken or sent.
- **Wake-word on the wearable**: rejected; voice requests go through STT on the server, so a voice
  photo is taken several seconds after the sentence (end of speech, BLE, STT, the command wait,
  the intent check, the long poll). The app button is immediate.

## Consequences

- Protocol 3: TAKE_PHOTO (0x18), PHOTO_START (0x04), PHOTO_FAILED (0x22), camera flag in
  DEVICE_STATUS. The app accepts protocols 2 and 3, so it still works with older firmware.
- Text in a photo reaches memory and the agent: the vision prompt treats it as content, not
  instructions; sending and deleting still need a confirmation.
- Requests the wearable never answers fail after `PHOTO_REQUEST_TIMEOUT_S` (90 s) with a message
  in the chat; a photo that arrives later is still accepted.
