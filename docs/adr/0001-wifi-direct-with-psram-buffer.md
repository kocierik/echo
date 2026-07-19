# Wi-Fi direct with PSRAM buffer for device-to-backend communication

The Wearable communicates with the backend exclusively over Wi-Fi using HTTP POST with chunked audio every 5-10 seconds. When Wi-Fi is unavailable, Segments are buffered in PSRAM (~240KB capacity, ~30 seconds of ADPCM audio) and flushed when connectivity resumes. BLE and a smartphone companion app are deferred to a later phase.

## Considered Options

- **BLE → Smartphone → Backend**: Would require developing a mobile app in the MVP, adding significant scope.
- **Wi-Fi only (no buffer)**: Simpler but loses audio during connectivity drops.
- **MQTT**: Good for small messages but unsuitable for streaming audio chunks.
- **WebSocket**: Lower latency but adds connection state management complexity unnecessary for a non-realtime "memory" use case.

## Consequences

- The device only works in Wi-Fi range (home, office). Acceptable for MVP.
- The architecture cleanly supports adding BLE as an alternative transport later — the backend receives audio via HTTP regardless of how it arrives.
- Short connectivity interruptions (< 30s of speech) don't lose data.
