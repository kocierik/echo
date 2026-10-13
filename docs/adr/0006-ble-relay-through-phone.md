# BLE relay through the phone instead of Wi-Fi direct

Supersedes [ADR 0001](0001-wifi-direct-with-psram-buffer.md).

The Wearable no longer talks to the backend. It stores every completed Segment in a 512 KB PSRAM ring buffer and relays the oldest one over BLE to the paired phone; the Flutter app reassembles it, uploads it with `POST /api/segments` and only then sends `UPLOAD_OK`, the single path that removes a Segment from the Wearable. The backend API is unchanged: it still receives ADPCM over HTTP, whoever sends it.

The BLE protocol uses framed transfers with sequence numbers, ACK windows, segment restart and a CRC32 per Segment. The phone also sends `SET_TIME` (time anchor for `recorded_at`) and `SET_MUTED` (persistent mute stored in NVS). The link uses BLE Secure Connections with bonding to a single phone; audio and control characteristics require encryption.

## Considered Options

- **Wi-Fi direct (ADR 0001)**: works only in known Wi-Fi networks, needs credentials on the device and costs more power than BLE; it covered home and office but not the day outside.
- **Phone as relay over BLE** (chosen): the phone is always with the user and already has connectivity (cellular or Wi-Fi), so the Wearable stays simple and low-power.
- **Phone streaming in real time**: lower latency, but any BLE or network drop would lose audio; memory is not a real-time use case.

## Consequences

- Echo depends on the phone app running: iOS background BLE (`bluetooth-central` + state restoration) is the main acceptance risk, verified by the core beta two-hour test.
- No data is lost on BLE or backend outages as long as the PSRAM buffer has room; when it is full the oldest Segments are dropped and counted (`DEVICE_STATUS` reports the dropped count).
- Wi-Fi credentials, the HTTP sender and NTP were removed from the firmware; time comes from the phone.
- The upload policy (cellular allowed or Wi-Fi only) is decided on the phone.
