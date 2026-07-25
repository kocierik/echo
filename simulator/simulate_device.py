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

# Optional: local transcription preview
try:
    from faster_whisper import WhisperModel
    WHISPER_AVAILABLE = True
except ImportError:
    WHISPER_AVAILABLE = False

# =============================================================================
# Configuration defaults
# =============================================================================
DEFAULT_SERVER = "http://localhost:8000"
DEFAULT_API_KEY = "my-secret-key"
DEFAULT_VAD_THRESHOLD = 500
DEFAULT_SEGMENT_DURATION = 15.0  # seconds
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

    def __init__(self, server_url: str, api_key: str, verbose: bool = False):
        self.endpoint = f"{server_url}/api/segments"
        self.api_key = api_key
        self.verbose = verbose

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
                if self.verbose:
                    print(f"    Server response: {data}")
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
    sender = Sender(args.server, args.api_key, verbose=args.verbose)

    # Load local Whisper model for transcription preview
    whisper_model = None
    if not args.no_transcribe and WHISPER_AVAILABLE:
        print(f"  📥 Loading Whisper '{args.whisper_model}' model (first time downloads ~150MB)...")
        whisper_model = WhisperModel(args.whisper_model, device="cpu", compute_type="int8")
        print("  ✓ Whisper model loaded.\n")
    elif not args.no_transcribe and not WHISPER_AVAILABLE:
        print("  ℹ Local transcription disabled (install faster-whisper to enable)")
        print("    pip install faster-whisper\n")

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
║  Gain:      {args.gain}x{' ' * 37}║
╚══════════════════════════════════════════════════╝
    """)
    print("🎙️  Listening... (speak to start recording, Ctrl+C to quit)\n")

    # State
    recording = False
    segment_buffer = []  # list of PCM frames (numpy arrays)
    segment_start_time = 0
    last_silence_ms = 0
    frame_count = 0
    max_energy_seen = 0

    # Pre-buffer: keep last 500ms of audio to capture speech onset
    pre_buffer_frames = int(0.5 / 0.032)  # ~15 frames = 500ms
    pre_buffer = []  # circular buffer of recent frames

    def audio_callback(indata, frames, time_info, status):
        nonlocal recording, segment_buffer, segment_start_time, last_silence_ms
        nonlocal frame_count, max_energy_seen

        if status:
            print(f"  ⚠ Audio status: {status}", file=sys.stderr)

        frame = indata[:, 0].copy()  # mono
        frame_int16 = (frame * 32767).astype(np.int16)

        # Apply gain
        if args.gain != 1.0:
            amplified = frame_int16.astype(np.int32) * int(args.gain)
            amplified = np.clip(amplified, -32768, 32767)
            frame_int16 = amplified.astype(np.int16)

        event = vad.process(frame_int16)
        frame_count += 1
        max_energy_seen = max(max_energy_seen, vad.energy)

        # Show energy level every ~1 second (every 31 frames at 32ms each)
        if frame_count % 31 == 0 and not recording:
            bar_len = min(vad.energy // 50, 40)
            bar = "█" * bar_len + "░" * (40 - bar_len)
            threshold_pos = min(args.vad_threshold // 50, 40)
            status_char = "🟢" if vad.energy > args.vad_threshold else "⚪"
            sys.stdout.write(
                f"\r  {status_char} Energy: {vad.energy:5d} [{bar}] "
                f"(threshold: {args.vad_threshold}, max: {max_energy_seen})"
            )
            sys.stdout.flush()

        if event == "speech_start":
            recording = True
            # Include pre-buffer (audio BEFORE VAD triggered) to capture onset
            segment_buffer = list(pre_buffer)
            segment_start_time = time.time() - (len(pre_buffer) * 0.032)  # adjust start time
            last_silence_ms = vad.silence_duration_ms
            sys.stdout.write("\r" + " " * 80 + "\r")  # clear energy bar
            print(f"  🔴 Recording... (energy: {vad.energy}, pre-buffer: {len(pre_buffer)} frames)")

        # Always maintain pre-buffer (rolling window of recent audio)
        if not recording:
            pre_buffer.append(frame_int16.copy())
            if len(pre_buffer) > pre_buffer_frames:
                pre_buffer.pop(0)

        if recording:
            segment_buffer.append(frame_int16.copy())

            # Check max duration (safety limit)
            elapsed = time.time() - segment_start_time
            if elapsed >= args.segment_duration:
                finalize_segment(segment_buffer, elapsed, last_silence_ms, sender, whisper_model)
                recording = False
                segment_buffer = []
                pre_buffer = []

        if event == "speech_end" and recording:
            # Speech ended naturally (pause detected) — finalize
            elapsed = time.time() - segment_start_time
            finalize_segment(segment_buffer, elapsed, last_silence_ms, sender, whisper_model)
            recording = False
            segment_buffer = []
            pre_buffer = []

    # Start audio stream
    try:
        with sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            blocksize=frame_size,
            callback=audio_callback,
        ):
            print("  (Press Ctrl+C to stop)\n")
            while True:
                time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    except Exception as e:
        print(f"\n❌ Error: {e}")
        print("   Make sure you have a microphone connected.")
        sys.exit(1)
    finally:
        # Force cleanup audio resources on Windows to avoid system freeze
        sd.stop()
        print("\n\n👋 Simulator stopped.")


def finalize_segment(frames: list, duration: float, silence_before_ms: int,
                     sender: Sender, whisper_model=None):
    """Encode collected frames to ADPCM and send."""
    if not frames:
        return

    # Concatenate all frames
    pcm_samples = np.concatenate(frames)
    duration_ms = int(duration * 1000)

    # Skip very short segments (< 500ms) — they're usually noise/clicks
    if duration_ms < 500:
        print(f"  ⏭ Skipped: too short ({duration_ms}ms)")
        return

    print(f"  ⬜ Segment: {duration_ms}ms, {len(pcm_samples)} samples")

    # Local transcription preview (free, no API cost)
    if whisper_model is not None:
        transcribe_local(pcm_samples, whisper_model)

    # Convert to bytes
    pcm_bytes = pcm_samples.tobytes()

    # Encode to ADPCM
    adpcm_data = encode_adpcm(pcm_bytes)
    ratio = len(pcm_bytes) / len(adpcm_data) if adpcm_data else 0
    print(f"  📦 ADPCM: {len(adpcm_data)} bytes (ratio: {ratio:.1f}:1)")

    # Send to backend
    sender.send(adpcm_data, duration_ms, silence_before_ms)
    print()


def transcribe_local(pcm_samples: np.ndarray, model):
    """Transcribe audio locally using faster-whisper (free, no API calls)."""
    import tempfile
    import wave

    # Write PCM to a temporary WAV file
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmp_path = f.name
        with wave.open(f, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(SAMPLE_RATE)
            wav.writeframes(pcm_samples.tobytes())

    try:
        segments, info = model.transcribe(tmp_path, language="it", beam_size=3)
        text = " ".join(seg.text.strip() for seg in segments)

        # Filter known Whisper hallucinations
        hallucinations = [
            "sottotitoli", "amara.org", "comunità", "MoraviCS",
            "Sottotitoli e revisione", "www.", ".org", ".com",
            "Grazie per aver guardato", "Iscriviti al canale",
        ]
        if text and not any(h.lower() in text.lower() for h in hallucinations):
            print(f"  💬 \"{text}\"")
        elif text:
            print(f"  💬 (hallucination filtered: \"{text[:50]}...\")")
        else:
            print(f"  💬 (silenzio / non riconosciuto)")
    except Exception as e:
        print(f"  ⚠ Transcription error: {e}")
    finally:
        import os
        os.unlink(tmp_path)


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
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Show full server response (segment ID, status)"
    )
    parser.add_argument(
        "-g", "--gain",
        type=float,
        default=1.0,
        help="Microphone gain multiplier (default: 1.0, try 5-10 if energy is low)"
    )
    parser.add_argument(
        "--no-transcribe",
        action="store_true",
        help="Disable local transcription preview"
    )
    parser.add_argument(
        "--whisper-model",
        default="base",
        choices=["tiny", "base", "small"],
        help="Local Whisper model size (default: base)"
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
