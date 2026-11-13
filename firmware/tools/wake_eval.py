"""How often wake phrase models fire on audio where nobody said them.

Run in a throwaway container, on the folder app.cli.export_wake_eval wrote, with the
models the pendant would run (esphome/micro-wake-word-models v2: pymicro-wakeword's own
okay_nabu is another model, with another cutoff):

    docker run --rm -v "$PWD/firmware/tools":/t:ro -v "$PWD/backend/.wake_eval":/d:ro \
        python:3.11 sh -c 'pip -q install pymicro-wakeword==2.5.0 && mkdir /m && cd /m && \
        for m in hey_jarvis hey_mycroft okay_nabu; do for e in json tflite; do curl -sfLO \
        https://github.com/esphome/micro-wake-word-models/raw/main/models/v2/$m.$e; done; \
        done && python /t/wake_eval.py --data /d --manifest /m/*.json'

Same features and decision as the pendant (wake_detector.h): TensorFlow's microfrontend,
the mean of the manifest's sliding window of probabilities against a cutoff. A segment
counts once, however many times it fires. Prints, per model and cutoff, the segments that
fired and false detections per hour of audio.
"""

import argparse
import csv
import wave
from pathlib import Path


def scan(model, features_factory, wav_path: Path) -> float:
    """The highest windowed probability the model reaches in one file."""
    model.reset()
    features = features_factory()
    with wave.open(str(wav_path), "rb") as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (16000, 1, 2):
            raise ValueError(f"{wav_path.name}: not 16 kHz mono 16-bit")
        pcm = audio.readframes(audio.getnframes())
    best = 0.0
    for slice_ in features.process_streaming(pcm):
        probability = model.process_streaming_prob(slice_)
        if probability is not None and probability > best:
            best = probability
    return best


def rates(peaks: list[float], hours: float, cutoffs: list[float]) -> list[tuple[float, int, float]]:
    """(cutoff, segments that fired, false detections per hour) for each cutoff."""
    out = []
    for cutoff in cutoffs:
        fired = sum(peak > cutoff for peak in peaks)
        out.append((cutoff, fired, fired / hours if hours > 0 else 0.0))
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--builtin", nargs="*", default=[], help="hey_jarvis hey_mycroft okay_nabu")
    parser.add_argument("--manifest", nargs="*", type=Path, default=[], help="model .json files")
    parser.add_argument("--cutoff", nargs="*", type=float, default=None)
    args = parser.parse_args()

    from pymicro_wakeword import MicroWakeWord, MicroWakeWordFeatures, Model

    models = [MicroWakeWord.from_builtin(Model(name)) for name in args.builtin]
    models += [MicroWakeWord.from_config(path) for path in args.manifest]

    rows = list(csv.DictReader(open(args.data / "labels.csv")))
    hours = sum(int(row["duration_ms"]) for row in rows) / 3_600_000
    print(f"{len(rows)} segments, {hours:.2f} hours of speech without any candidate phrase")
    for model in models:
        peaks = [scan(model, MicroWakeWordFeatures, args.data / row["file"]) for row in rows]
        own = model.probability_cutoff
        cutoffs = args.cutoff or sorted({round(own - 0.02, 2), own, min(round(own + 0.02, 2), 0.99)})
        for cutoff, fired, per_hour in rates(peaks, hours, cutoffs):
            mark = " (manifest)" if abs(cutoff - own) < 1e-9 else ""
            print(f"{model.wake_word:12s} cutoff {cutoff:.2f}{mark}: {fired} segments, "
                  f"{per_hour:.2f} false detections per hour")


# Self-check: no audio is no rate, not a division by zero
assert rates([], 0.0, [0.97]) == [(0.97, 0, 0.0)]
assert rates([0.99, 0.5], 0.5, [0.97]) == [(0.97, 1, 2.0)]

if __name__ == "__main__":
    main()
