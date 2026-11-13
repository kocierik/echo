"""Before each build: src/wake_model.h from models/wake.json and the .tflite it names."""
import json
import os

Import("env")  # noqa: F821 (PlatformIO)

project = env.subst("$PROJECT_DIR")  # noqa: F821
manifest = json.load(open(os.path.join(project, "models", "wake.json")))
micro = manifest["micro"]
data = open(os.path.join(project, "models", manifest["model"]), "rb").read()

lines = [
    "#pragma once",
    f"// Generated from models/wake.json ({manifest['wake_word']}, by {manifest['author']}):",
    "// esphome/micro-wake-word-models, Apache License 2.0. Do not edit: see models/README.md",
    "#include <cstddef>",
    f'#define WAKE_PHRASE "{manifest["wake_word"]}"',
    f"#define WAKE_PROBABILITY_CUTOFF {float(micro['probability_cutoff'])}f",
    f"#define WAKE_SLIDING_WINDOW {int(micro['sliding_window_size'])}",
    f"#define WAKE_FEATURE_STEP_MS {int(micro['feature_step_size'])}",
    f"#define WAKE_TENSOR_ARENA_BYTES {int(micro['tensor_arena_size'])}",
    "alignas(16) static const unsigned char WAKE_MODEL[] = {",
]
lines += ["  " + ", ".join(f"0x{b:02x}" for b in data[i:i + 16]) + "," for i in range(0, len(data), 16)]
lines += ["};", f"static const size_t WAKE_MODEL_SIZE = {len(data)};", ""]

out = os.path.join(project, "src", "wake_model.h")
text = "\n".join(lines)
if not os.path.exists(out) or open(out).read() != text:  # unchanged: no rebuild
    open(out, "w").write(text)
