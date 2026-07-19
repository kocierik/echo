# Echo Device Simulator

Simulates the ESP32-S3 wearable device from your PC microphone. Records audio, applies Voice Activity Detection (VAD), encodes to ADPCM, and sends segments to the backend via HTTP POST — exactly as the real device would.

## Install

```bash
cd simulator
pip install -r requirements.txt
```

## Usage

```bash
# Basic — uses default server (localhost:8000) and API key
python simulate_device.py

# Custom server and key
python simulate_device.py -s http://your-server:8000 -k your-api-key

# Adjust VAD sensitivity (lower = more sensitive)
python simulate_device.py -t 300

# List audio devices
python simulate_device.py --list-devices

# Use a specific microphone
python simulate_device.py --device 2
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `-s, --server` | `http://localhost:8000` | Backend URL |
| `-k, --api-key` | `my-secret-key` | API key |
| `-t, --vad-threshold` | `500` | VAD energy threshold (lower = more sensitive) |
| `-d, --segment-duration` | `5.0` | Max segment duration (seconds) |
| `--silence-timeout` | `2.0` | Silence before ending segment (seconds) |
| `--list-devices` | — | Show available microphones |
| `--device` | system default | Audio input device index |

## How it works

```
Microphone → PCM 16kHz/16bit/mono → VAD → ADPCM encode → HTTP POST → Backend
```

1. Captures audio in 32ms frames (512 samples) — same as the firmware
2. VAD detects speech using RMS energy threshold
3. When speech starts, accumulates frames
4. When speech ends (or max duration reached), encodes to ADPCM
5. Sends the ADPCM segment via HTTP POST to `/api/segments`
6. Backend processes: STT → Entity extraction → Embeddings

## Calibrating VAD

The default threshold (500) works for quiet environments. Adjust based on your setup:

- **Quiet room**: 300-500
- **Office with background noise**: 800-1500
- **Noisy environment**: 2000+

Run with `-t 0` to see the energy levels reported, then pick a threshold above your background noise floor.
