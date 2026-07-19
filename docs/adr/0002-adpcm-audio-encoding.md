# ADPCM encoding for audio transmission

Audio captured by the Wearable's microphone is encoded in IMA-ADPCM before transmission and buffering. This provides 4:1 compression over raw PCM at negligible CPU cost on the ESP32-S3, resulting in ~8KB/s at 16kHz/16bit mono.

## Considered Options

- **Raw PCM (WAV)**: No compression, ~32KB/s. Fills the PSRAM buffer in ~7 seconds and demands more Wi-Fi bandwidth.
- **Opus**: Excellent compression (~10:1) but computationally expensive on ESP32-S3 with no mature library support.
- **μ-law/A-law**: Only 2:1 compression; marginal benefit for the same integration effort.

## Consequences

- PSRAM buffer holds ~30 seconds of audio (vs ~7s with PCM).
- The backend must decode ADPCM before passing to STT. This is trivial (standard codec, libraries available in Python).
- If STT quality proves insufficient with ADPCM artifacts, switching to raw PCM is a simple change (remove encoder on device, remove decoder on backend).
