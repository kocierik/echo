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
DEFAULT_SEGMENT_DURATION = 30.0  # seconds
DEFAULT_SILENCE_TIMEOUT = 2.0  # seconds of silence before ending segment

SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "int16"


# =============================================================================
# VAD (Voice Activity Detection)
# =============================================================================
class VAD:
    """Energy-based VAD matching the firmware implementation."""

    def __init__(self, threshold: int = 500, speech_start_frames: int = 3, speech_end_frames: int = 60):
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
║  Mode:      {'CONTINUOUS' if args.continuous else 'VAD-driven':<36} ║
║  VAD:       threshold={args.vad_threshold:<26} ║
║  Segment:   {args.segment_duration}s max duration{' ' * 22}║
║  Silence:   {args.silence_timeout}s timeout{' ' * 25}║
║  Gain:      {args.gain}x{' ' * 37}║
╚══════════════════════════════════════════════════╝
    """)

    # --- CONTINUOUS MODE ---
    if args.continuous:
        print("🎙️  CONTINUOUS mode — recording everything, Ctrl+C to quit\n")
        run_continuous(args, sender, whisper_model, frame_size)
        return

    print("🎙️  Listening... (speak to start recording, Ctrl+C to quit)\n")

    # State
    recording = False
    segment_buffer = []  # list of PCM frames (numpy arrays)
    segment_start_time = 0
    last_silence_ms = 0
    frame_count = 0
    max_energy_seen = 0
    pending_finalize = False  # waiting for continuation or timeout
    pending_finalize_time = 0  # when speech_end was detected
    CONTINUATION_WINDOW = 0.5  # seconds to wait before truly finalizing

    # Pre-buffer: keep last 500ms of audio to capture speech onset
    pre_buffer_frames = int(0.5 / 0.032)  # ~15 frames = 500ms
    pre_buffer = []  # circular buffer of recent frames

    def audio_callback(indata, frames, time_info, status):
        nonlocal recording, segment_buffer, segment_start_time, last_silence_ms
        nonlocal frame_count, max_energy_seen, pre_buffer

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
            if pending_finalize:
                # Speech resumed within continuation window — cancel finalize
                pending_finalize = False
                # Keep recording, don't break the segment
            elif not recording:
                recording = True
                # Include pre-buffer (audio BEFORE VAD triggered) to capture onset
                segment_buffer = list(pre_buffer)
                segment_start_time = time.time() - (len(pre_buffer) * 0.032)
                last_silence_ms = vad.silence_duration_ms
                sys.stdout.write("\r" + " " * 80 + "\r")  # clear energy bar
                print(f"  🔴 Recording... (energy: {vad.energy}, pre-buffer: {len(pre_buffer)} frames)")

        # Always maintain pre-buffer (rolling window of recent audio)
        if not recording and not pending_finalize:
            pre_buffer.append(frame_int16.copy())
            if len(pre_buffer) > pre_buffer_frames:
                pre_buffer.pop(0)

        if recording or pending_finalize:
            segment_buffer.append(frame_int16.copy())

            # Check max duration (safety limit)
            elapsed = time.time() - segment_start_time
            if elapsed >= args.segment_duration:
                finalize_segment(segment_buffer, elapsed, last_silence_ms, sender, whisper_model, save_wav=args.save_wav)
                recording = False
                pending_finalize = False
                segment_buffer = []
                pre_buffer = []

        if event == "speech_end" and recording:
            # Don't finalize immediately — wait for continuation window
            pending_finalize = True
            pending_finalize_time = time.time()
            recording = False  # stop treating as active speech

        # Check if continuation window expired (truly done talking)
        if pending_finalize and (time.time() - pending_finalize_time) > CONTINUATION_WINDOW:
            elapsed = time.time() - segment_start_time
            finalize_segment(segment_buffer, elapsed, last_silence_ms, sender, whisper_model, save_wav=args.save_wav)
            pending_finalize = False
            segment_buffer = []
            pre_buffer = []

    # Start audio stream — use blocking read instead of callback to avoid
    # Windows freeze on Ctrl+C (callback threads deadlock on shutdown)
    try:
        stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            blocksize=frame_size,
        )
        stream.start()
        print("  (Press Ctrl+C to stop)\n")

        while True:
            frame_data, overflowed = stream.read(frame_size)
            if overflowed:
                print("  ⚠ Audio buffer overflow", file=sys.stderr)
            audio_callback(frame_data, frame_size, None, None)

    except KeyboardInterrupt:
        # Finalize any in-progress segment before exiting
        if (recording or pending_finalize) and segment_buffer:
            elapsed = time.time() - segment_start_time
            print("\n  ⏹ Finalizing last segment before exit...")
            finalize_segment(segment_buffer, elapsed, last_silence_ms, sender, whisper_model, save_wav=args.save_wav)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        print("   Make sure you have a microphone connected.")
        sys.exit(1)
    finally:
        try:
            stream.stop()
            stream.close()
        except Exception:
            pass
        print("\n\n👋 Simulator stopped.")
        # Force kill to avoid audio subsystem deadlock (PulseAudio/PipeWire bug)
        import os
        os._exit(0)


def run_continuous(args, sender, whisper_model, frame_size):
    """Continuous recording mode: fixed-duration chunks, skip silence-only.

    Records everything in chunks of segment_duration seconds.
    Only skips chunks that contain zero speech (100% silence).
    No audio is ever lost — ideal for maximum transcription quality.
    """
    vad = VAD(threshold=args.vad_threshold)
    chunk_frames = []
    chunk_start_time = time.time()
    has_speech = False
    chunk_count = 0

    try:
        stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            blocksize=frame_size,
        )
        stream.start()

        while True:
            frame_data, overflowed = stream.read(frame_size)
            if overflowed:
                print("  ⚠ Audio buffer overflow", file=sys.stderr)

            frame = frame_data[:, 0].copy()
            frame_int16 = (frame * 32767).astype(np.int16)

            # Apply gain
            if args.gain != 1.0:
                amplified = frame_int16.astype(np.int32) * int(args.gain)
                amplified = np.clip(amplified, -32768, 32767)
                frame_int16 = amplified.astype(np.int16)

            # Track if there's any speech in this chunk
            vad.process(frame_int16)
            if vad.energy > args.vad_threshold:
                has_speech = True

            chunk_frames.append(frame_int16.copy())

            # Check if chunk duration reached
            elapsed = time.time() - chunk_start_time
            if elapsed >= args.segment_duration:
                if has_speech:
                    chunk_count += 1
                    print(f"  📤 Chunk #{chunk_count}: {elapsed:.1f}s (has speech)")
                    finalize_segment(
                        chunk_frames, elapsed, 0, sender, whisper_model,
                        save_wav=args.save_wav,
                    )
                else:
                    print(f"  ⏭ Chunk skipped: {elapsed:.1f}s (silence only)")

                # Reset for next chunk
                chunk_frames = []
                chunk_start_time = time.time()
                has_speech = False

    except KeyboardInterrupt:
        # Finalize remaining frames
        if chunk_frames and has_speech:
            elapsed = time.time() - chunk_start_time
            print(f"\n  ⏹ Finalizing last chunk ({elapsed:.1f}s)...")
            finalize_segment(
                chunk_frames, elapsed, 0, sender, whisper_model,
                save_wav=args.save_wav,
            )
    finally:
        try:
            stream.stop()
            stream.close()
        except Exception:
            pass
        print("\n\n👋 Simulator stopped.")
        import os
        os._exit(0)


def finalize_segment(frames: list, duration: float, silence_before_ms: int,
                     sender: Sender, whisper_model=None, save_wav: bool = False):
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

    # Save WAV for debugging (before ADPCM encoding)
    if save_wav:
        import wave
        from pathlib import Path

        wav_dir = Path("debug_segments")
        wav_dir.mkdir(exist_ok=True)
        wav_name = f"segment_{int(time.time())}_{duration_ms}ms.wav"
        wav_path = wav_dir / wav_name
        with wave.open(str(wav_path), "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(pcm_samples.tobytes())
        print(f"  💾 Saved: {wav_path}")

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
        "--save-wav",
        action="store_true",
        help="Save each segment as WAV in debug_segments/ (for debugging audio quality)"
    )
    parser.add_argument(
        "--continuous",
        action="store_true",
        help="Continuous recording mode: record everything in fixed chunks, skip silence-only chunks. "
             "Best transcription quality but higher STT API cost."
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
