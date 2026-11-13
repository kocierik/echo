# Wake phrase model

`wake.json` is the manifest of the model the pendant runs; its `model` field names the
`.tflite` beside it. `tools/gen_wake_model.py` turns both into `src/wake_model.h` before
each build (the header is not committed). The models come from
https://github.com/esphome/micro-wake-word-models (`models/v2`), Apache License 2.0.

To change the phrase: put the new `.tflite` here and replace `wake.json` with its manifest.
