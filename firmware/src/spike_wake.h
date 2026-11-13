#pragma once
// SPIKE ONLY (branch spike/wake-word): three ready-made wake phrases on the loop's audio,
// to measure frame time, heap and how often each is heard. Never merged.

#include <Arduino.h>
#include <esp_heap_caps.h>

#include <frontend.h>
#include <frontend_util.h>

#include "tensorflow/lite/micro/micro_allocator.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/micro/micro_resource_variable.h"
#include "tensorflow/lite/schema/schema_generated.h"

#include "spike_models.h"

namespace spike {

constexpr size_t FEATURES = 40;
constexpr size_t MAX_WINDOW = 10;
constexpr uint32_t REFRACTORY_MS = 2000;  // one utterance is one detection

struct Detector {
    const char* name;
    const unsigned char* data;
    size_t arenaBytes;
    float cutoff;
    uint8_t window;
    uint8_t* arena = nullptr;
    uint8_t* variableArena = nullptr;
    tflite::MicroInterpreter* interpreter = nullptr;
    int stride = 0;
    int filled = 0;
    uint8_t probabilities[MAX_WINDOW] = {};
    uint8_t next = 0;
    uint32_t quietUntilMs = 0;
    uint32_t heard = 0;
};

static Detector detectors[] = {
    {"hey_jarvis", SPIKE_HEY_JARVIS, 22860 + 4096, 0.97f, 5},
    {"hey_mycroft", SPIKE_HEY_MYCROFT, 23628 + 4096, 0.95f, 5},
    {"okay_nabu", SPIKE_OKAY_NABU, 26080 + 4096, 0.97f, 5},
};

static FrontendState frontend;
static tflite::MicroMutableOpResolver<20> resolver;

inline bool addOps() {
    return resolver.AddCallOnce() == kTfLiteOk && resolver.AddVarHandle() == kTfLiteOk &&
           resolver.AddReshape() == kTfLiteOk && resolver.AddReadVariable() == kTfLiteOk &&
           resolver.AddStridedSlice() == kTfLiteOk && resolver.AddConcatenation() == kTfLiteOk &&
           resolver.AddAssignVariable() == kTfLiteOk && resolver.AddConv2D() == kTfLiteOk &&
           resolver.AddMul() == kTfLiteOk && resolver.AddAdd() == kTfLiteOk &&
           resolver.AddMean() == kTfLiteOk && resolver.AddFullyConnected() == kTfLiteOk &&
           resolver.AddLogistic() == kTfLiteOk && resolver.AddQuantize() == kTfLiteOk &&
           resolver.AddDepthwiseConv2D() == kTfLiteOk && resolver.AddAveragePool2D() == kTfLiteOk &&
           resolver.AddMaxPool2D() == kTfLiteOk && resolver.AddPad() == kTfLiteOk &&
           resolver.AddPack() == kTfLiteOk && resolver.AddSplitV() == kTfLiteOk;
}

inline bool beginOne(Detector& d) {
    d.arena = static_cast<uint8_t*>(heap_caps_malloc(d.arenaBytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    d.variableArena = static_cast<uint8_t*>(heap_caps_malloc(1024, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    if (d.arena == nullptr || d.variableArena == nullptr) return false;
    const tflite::Model* model = tflite::GetModel(d.data);
    if (model->version() != TFLITE_SCHEMA_VERSION) return false;
    tflite::MicroAllocator* variableAllocator = tflite::MicroAllocator::Create(d.variableArena, 1024);
    tflite::MicroResourceVariables* variables = tflite::MicroResourceVariables::Create(variableAllocator, 20);
    d.interpreter = new tflite::MicroInterpreter(model, resolver, d.arena, d.arenaBytes, variables);
    if (d.interpreter->AllocateTensors() != kTfLiteOk) return false;
    TfLiteTensor* input = d.interpreter->input(0);
    if (input->type != kTfLiteInt8 || input->dims->size != 3 || input->dims->data[2] != FEATURES) {
        return false;
    }
    d.stride = input->dims->data[1];
    Serial.printf("[Spike] %s ready: stride %d, arena used %u of %u\n", d.name, d.stride,
                  static_cast<unsigned>(d.interpreter->arena_used_bytes()),
                  static_cast<unsigned>(d.arenaBytes));
    return true;
}

inline bool begin() {
    FrontendConfig config;
    FrontendFillConfigWithDefaults(&config);
    config.window.size_ms = 30;
    config.window.step_size_ms = 10;
    config.filterbank.num_channels = FEATURES;
    config.filterbank.lower_band_limit = 125.0f;
    config.filterbank.upper_band_limit = 7500.0f;
    config.noise_reduction.smoothing_bits = 10;
    config.noise_reduction.even_smoothing = 0.025f;
    config.noise_reduction.odd_smoothing = 0.06f;
    config.noise_reduction.min_signal_remaining = 0.05f;
    config.pcan_gain_control.enable_pcan = 1;
    config.pcan_gain_control.strength = 0.95f;
    config.pcan_gain_control.offset = 80.0f;
    config.pcan_gain_control.gain_bits = 21;
    config.log_scale.enable_log = 1;
    config.log_scale.scale_shift = 6;
    if (!FrontendPopulateState(&config, &frontend, 16000)) return false;
    if (!addOps()) return false;
    for (Detector& d : detectors) {
        if (!beginOne(d)) {
            Serial.printf("[Spike] %s failed to start\n", d.name);
            return false;
        }
    }
    Serial.printf("[Spike] free internal heap %u\n",
                  static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)));
    return true;
}

/** One 10 ms slice of features into every model. */
inline void slice(const uint16_t* values) {
    // The frontend's uint16 scaled to the models' int8, as TensorFlow's micro_speech example does
    int8_t features[FEATURES];
    for (size_t i = 0; i < FEATURES; ++i) {
        constexpr int32_t scale = 256;
        constexpr int32_t divisor = 666;  // 25.6 * 26.0, rounded
        int32_t value = ((static_cast<int32_t>(values[i]) * scale) + (divisor / 2)) / divisor - 128;
        features[i] = static_cast<int8_t>(value < -128 ? -128 : (value > 127 ? 127 : value));
    }
    const uint32_t now = millis();
    for (Detector& d : detectors) {
        TfLiteTensor* input = d.interpreter->input(0);
        memcpy(input->data.int8 + d.filled * FEATURES, features, FEATURES);
        if (++d.filled < d.stride) continue;
        d.filled = 0;
        if (d.interpreter->Invoke() != kTfLiteOk) continue;
        d.probabilities[d.next] = d.interpreter->output(0)->data.uint8[0];
        d.next = (d.next + 1) % d.window;
        uint32_t sum = 0;
        for (uint8_t i = 0; i < d.window; ++i) sum += d.probabilities[i];
        const float mean = sum / (255.0f * d.window);
        if (mean > d.cutoff && static_cast<int32_t>(now - d.quietUntilMs) >= 0) {
            ++d.heard;
            d.quietUntilMs = now + REFRACTORY_MS;
            Serial.printf("[Wake] heard %s p=%.3f (total %lu)\n", d.name, mean,
                          static_cast<unsigned long>(d.heard));
        }
    }
}

inline void feed(const int16_t* samples, size_t count) {
    while (count > 0) {
        size_t read = 0;
        FrontendOutput output = FrontendProcessSamples(&frontend, samples, count, &read);
        samples += read;
        count -= read;
        if (output.values != nullptr && output.size == FEATURES) slice(output.values);
        if (read == 0) break;
    }
}

}  // namespace spike
