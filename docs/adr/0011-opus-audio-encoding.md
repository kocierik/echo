# Opus audio encoding on the wearable

Supersedes [0002](0002-adpcm-audio-encoding.md). Up to firmware 0.8 a segment was IMA-ADPCM:
8 KB a second, which filled the BLE link and the phone's uploads, and its artifacts cost
transcription accuracy. Opus turned out to run comfortably on the ESP32-S3 at 80 MHz.

## Decision

- **Opus, 16 kHz mono, VOIP mode, 20 ms frames** (`firmware/src/opus_codec.h`,
  library `sh123/esp32_opus`). Firmware 0.9.0 at 16 kbit/s; 0.9.3 raised it to
  **32 kbit/s** (~4 KB a second), where transcription stops improving.
- **A segment is a small container** (`opus_segment.h`): a magic header, then each frame's
  length and bytes. The server tells it from ADPCM by the magic and decodes it with
  `opuslib` (`services/segment_audio.py`); ADPCM still decodes, for segments recorded by
  older firmware and kept on a microSD.
- The BLE protocol did not change: a segment is opaque bytes with its length and CRC.

## Consequences

- Half the bytes of ADPCM over BLE and to the server, with better transcription.
- The loop's stack is 48 KB (libopus keeps its scratch there); frame time is logged at
  each segment (`[Main] frame time`) to check 80 MHz keeps up.
- The server image needs the system's libopus.
