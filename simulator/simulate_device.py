"""Echo Device Simulator — simulates the ESP32-S3 wearable from your PC microphone.

Records audio, applies VAD, encodes to ADPCM, and sends to the backend via HTTP POST.
"""

import argparse
import math
import struct
import sys
import time
from datetime import datetime, timezone
from io import BytesIO

import requests
import sounddevice as sd
import numpy as np

from adpcm_encode import encode_adpcm

# =============================================================================
# Configuration defaults
# =============================================================================
DEFAULT_SERVER = "http://localhost:8000"
DEFAULT_API_KEY = "my-secret-key"
DEFAULT_VAD_THRESHOLD = 500
DEFAULT_SEGMENT_DURATION = 5.0  # seconds
DEFAULT_SILENCE_TIMEOUT = 2.0  # seconds of silence before ending segment

SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "int16"


# =============================================================================
# VAD (Voice Activity Detection)
# =============================================================================
class VAD:
    """Energy-based VAD matching the firmware implementation."""

    def __init__(self, threshold: int = 500, speech_start_frames: int = 3, speech_end_frames: int = 30):
        self.threshold = threshold
        self.speech_start_frames = speech_start_frames
        self.speech_end_frames = speech_end_frames
        self.state = "silence"  # silence | speech
        self._speech_count = 0
        self._silence_count = 0
        self._last_silence_start = time.time()
        self.energy = 0

    def process(self, frame: np.ndarray) -> str:
        """Process an audio frame and return state transition.

        Returns:
            'speech_start' | 'speech_end' | 'speech' | 'silence'
        """
        # Calculate RMS energy
        self.energy = int(np.sqrt(np.mean(frame.astype(np.float64) ** 2)))
        has_speech = self.energy > self.threshold

        if self.state == "silence":
            if has_speech:
                self._speech_count += 1
                if self._speech_count >= self.speech_start_frames:
                    self.state = "speech"
                    self._silence_count = 0
                    return "speech_start"
            else:
                self._speech_count = 0
            return "silence"

        else:  # state == "speech"
            if not has_speech:
                self._silence_count += 1
                if self._silence_count >= self.speech_end_frames:
                    self.state = "silence"
                    self._speech_count = 0
                    self._last_silence_start = time.time()
                    return "speech_end"
            else:
                self._silence_count = 0
            return "speech"

    @property
    def silence_duration_ms(self) -> int:
        """How long we've been silent in ms."""
        if self.state == "speech":
            return 0
        return int((time.time() - self._last_silence_start) * 1000)


# =============================================================================
# HTTP Sender
# =============================================================================
class Sender:
    """Sends ADPCM segments to the backend."""

    def __init__(self, server_url: str, api_key: str):
        self.endpoint = f"{server_url}/api/segments"
        self.api_key = api_key

    def send(self, adpcm_data: bytes, duration_ms: int, silence_before_ms: int) -> bool:
        """Send an ADPCM segment to the backend.

        Returns True if successful.
        """
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        headers = {
            "X-API-Key": self.api_key,
            "X-Recorded-At": timestamp,
            "X-Duration-Ms": str(duration_ms),
            "X-Silence-Before-Ms": str(silence_before_ms),
        }

        files = {
            "audio": ("segment.adpcm", BytesIO(adpcm_data), "application/octet-stream"),
        }

        try:
            resp = requests.post(self.endpoint, headers=headers, files=files, timeout=10)
            if resp.status_code == 201:
                data = resp.json()
                print(f"  ✓ Sent {len(adpcm_data)} bytes → segment {data['id'][:8]}...")
                return True
            else:
                print(f"  ✗ Server returned {resp.status_code}: {resp.text[:100]}")
                return False
        except requests.exceptions.ConnectionError:
            print(f"  ✗ Cannot connect to {self.endpoint}")
            return False
        except Exception as e:
            print(f"  ✗ Error: {e}")
            return False


# =============================================================================
# Main Simulator
# =============================================================================
def run_simulator(args):
    """Main loop: capture → VAD → encode → send."""
    vad = VAD(threshold=args.vad_threshold)
    sender = Sender(args.server, args.api_key)

    frame_size = int(SAMPLE_RATE * 0.032)  # 32ms frames (512 samples) — same as firmware
    segment_max_samples = int(SAMPLE_RATE * args.segment_duration)

    print(f"""
╔══════════════════════════════════════════════════╗
║         Echo Device Simulator                    ║
╠══════════════════════════════════════════════════╣
║  Server:    {args.server:<36} ║
║  VAD:       threshold={args.vad_threshold:<26} ║
║  Segment:   {args.segment_duration}s max duration{' ' * 22}║
║  Silence:   {args.silence_timeout}s timeout{' ' * 25}║
╚══════════════════════════════════════════════════╝
    """)
    print("🎙️  Listening... (speak to start recording, Ctrl+C to quit)\n")

    # State
    recording = False
    segment_buffer = []  # list of PCM frames (numpy arrays)
    segment_start_time = 0
    last_silence_ms = 0

    def audio_callback(indata, frames, time_info, status):
        nonlocal recording, segment_buffer, segment_start_time, last_silence_ms

        if status:
            print(f"  ⚠ Audio status: {status}", file=sys.stderr)

        frame = indata[:, 0].copy()  # mono
        frame_int16 = (frame * 32767).astype(np.int16) if frame.dtype != np.int16 else frame

        event = vad.process(frame_int16)

        if event == "speech_start":
            recording = True
            segment_buffer = []
            segment_start_time = time.time()
            last_silence_ms = vad.silence_duration_ms
            print(f"  🔴 Recording... (energy: {vad.energy})")

        if recording:
            segment_buffer.append(frame_int16.copy())

            # Check max duration
            elapsed = time.time() - segment_start_time
            if elapsed >= args.segment_duration:
                finalize_segment(segment_buffer, elapsed, last_silence_ms, sender)
                recording = False
                segment_buffer = []

        if event == "speech_end" and recording:
            elapsed = time.time() - segment_start_time
            finalize_segment(segment_buffer, elapsed, last_silence_ms, sender)
            recording = False
            segment_buffer = []

    # Start audio stream
    try:
        with sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=frame_size,
            callback=audio_callback,
        ):
            print("  (Press Ctrl+C to stop)\n")
            while True:
                time.sleep(0.1)
    except KeyboardInterrupt:
        print("\n\n👋 Simulator stopped.")
    except Exception as e:
        print(f"\n❌ Error: {e}")
        print("   Make sure you have a microphone connected.")
        sys.exit(1)


def finalize_segment(frames: list, duration: float, silence_before_ms: int, sender: Sender):
    """Encode collected frames to ADPCM and send."""
    if not frames:
        return

    # Concatenate all frames
    pcm_samples = np.concatenate(frames)
    duration_ms = int(duration * 1000)

    print(f"  ⬜ Segment: {duration_ms}ms, {len(pcm_samples)} samples")

    # Convert to bytes
    pcm_bytes = pcm_samples.tobytes()

    # Encode to ADPCM
    adpcm_data = encode_adpcm(pcm_bytes)
    ratio = len(pcm_bytes) / len(adpcm_data) if adpcm_data else 0
    print(f"  📦 ADPCM: {len(adpcm_data)} bytes (ratio: {ratio:.1f}:1)")

    # Send to backend
    sender.send(adpcm_data, duration_ms, silence_before_ms)
    print()


# =============================================================================
# CLI
# =============================================================================
def main():
    parser = argparse.ArgumentParser(
        description="Echo Device Simulator — simulates the wearable from your PC microphone"
    )
    parser.add_argument(
        "-s", "--server",
        default=DEFAULT_SERVER,
        help=f"Backend server URL (default: {DEFAULT_SERVER})"
    )
    parser.add_argument(
        "-k", "--api-key",
        default=DEFAULT_API_KEY,
        help=f"API key for authentication (default: {DEFAULT_API_KEY})"
    )
    parser.add_argument(
        "-t", "--vad-threshold",
        type=int,
        default=DEFAULT_VAD_THRESHOLD,
        help=f"VAD energy threshold (default: {DEFAULT_VAD_THRESHOLD})"
    )
    parser.add_argument(
        "-d", "--segment-duration",
        type=float,
        default=DEFAULT_SEGMENT_DURATION,
        help=f"Max segment duration in seconds (default: {DEFAULT_SEGMENT_DURATION})"
    )
    parser.add_argument(
        "--silence-timeout",
        type=float,
        default=DEFAULT_SILENCE_TIMEOUT,
        help=f"Silence timeout in seconds (default: {DEFAULT_SILENCE_TIMEOUT})"
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List available audio input devices and exit"
    )
    parser.add_argument(
        "--device",
        type=int,
        default=None,
        help="Audio input device index (use --list-devices to see options)"
    )

    args = parser.parse_args()

    if args.list_devices:
        print(sd.query_devices())
        sys.exit(0)

    if args.device is not None:
        sd.default.device[0] = args.device

    run_simulator(args)


if __name__ == "__main__":
    main()
