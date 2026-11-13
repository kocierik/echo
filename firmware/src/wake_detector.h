#pragma once

// Only with WAKE_WORD_ENABLED: the model (wake_model.h) and TensorFlow Lite Micro are
// compiled in only then.

#include <Arduino.h>
#include <esp_heap_caps.h>

#include <frontend.h>
#include <frontend_util.h>

#include "tensorflow/lite/micro/micro_allocator.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/micro/micro_resource_variable.h"
#include "tensorflow/lite/schema/schema_generated.h"

#include "config.h"
#include "wake_model.h"

/**
 * The wake phrase, heard on the pendant: a microWakeWord model (models/wake.json) on the
 * loop's amplified audio. Only a hint for instant feedback: the server decides on the
 * transcript. 40 spectrogram features every 10 ms (TensorFlow's microfrontend), the
 * model run every `stride` slices; a detection is the mean of the last
 * WAKE_SLIDING_WINDOW probabilities above WAKE_PROBABILITY_CUTOFF.
 *
 * A detector that cannot start leaves Echo listening as before: begin() is false, feed()
 * never detects.
 */
class WakeDetector {
public:
    static constexpr size_t FEATURES = 40;

    bool begin() {
        if (!startFrontend() || !addOps()) return false;
        // The model's own arena, plus the margin its manifest leaves out (operator state)
        _arenaBytes = WAKE_TENSOR_ARENA_BYTES + ARENA_MARGIN;
        _arena = static_cast<uint8_t*>(
            heap_caps_malloc(_arenaBytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
        _variableArena = static_cast<uint8_t*>(
            heap_caps_malloc(VARIABLE_ARENA_BYTES, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
        if (_arena == nullptr || _variableArena == nullptr) return fail("no memory");

        const tflite::Model* model = tflite::GetModel(WAKE_MODEL);
        if (model->version() != TFLITE_SCHEMA_VERSION) return fail("model schema");
        tflite::MicroAllocator* variableAllocator =
            tflite::MicroAllocator::Create(_variableArena, VARIABLE_ARENA_BYTES);
        tflite::MicroResourceVariables* variables =
            tflite::MicroResourceVariables::Create(variableAllocator, MAX_VARIABLES);
        if (variables == nullptr) return fail("variables");
        _interpreter =
            new tflite::MicroInterpreter(model, _resolver, _arena, _arenaBytes, variables);
        if (_interpreter->AllocateTensors() != kTfLiteOk) return fail("tensors");

        TfLiteTensor* input = _interpreter->input(0);
        TfLiteTensor* output = _interpreter->output(0);
        if (input->type != kTfLiteInt8 || input->dims->size != 3 ||
            input->dims->data[2] != static_cast<int>(FEATURES) ||
            output->type != kTfLiteUInt8) {
            return fail("model shape");
        }
        _stride = input->dims->data[1];
        _ready = true;
        Serial.printf("[Wake] \"%s\" ready: arena %u of %u bytes, %u bytes of heap left\n",
                      WAKE_PHRASE, static_cast<unsigned>(_interpreter->arena_used_bytes()),
                      static_cast<unsigned>(_arenaBytes),
                      static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)));
        return true;
    }

    bool isReady() const { return _ready; }

    /** The loop's frame; true when the phrase was detected in it. */
    bool feed(const int16_t* samples, size_t count) {
        if (!_ready) return false;
        bool detected = false;
        while (count > 0) {
            size_t read = 0;
            FrontendOutput output = FrontendProcessSamples(&_frontend, samples, count, &read);
            samples += read;
            count -= read;
            if (output.values != nullptr && output.size == FEATURES && slice(output.values)) {
                detected = true;
            }
            if (read == 0) break;
        }
        return detected;
    }

    /** The microphone restarted: what came before is another recording. */
    void reset() {
        if (!_ready) return;
        FrontendReset(&_frontend);
        _interpreter->Reset();
        clearProbabilities();
        _filled = 0;
    }

private:
    static constexpr size_t ARENA_MARGIN = 4096;
    static constexpr size_t VARIABLE_ARENA_BYTES = 1024;
    static constexpr int MAX_VARIABLES = 20;
    static constexpr size_t MAX_WINDOW = 16;
    static_assert(WAKE_SLIDING_WINDOW >= 1 && WAKE_SLIDING_WINDOW <= MAX_WINDOW,
                  "The manifest's sliding window must fit");
    static_assert(WAKE_FEATURE_STEP_MS == 10, "The features are computed every 10 ms");

    bool fail(const char* why) {
        Serial.printf("[Wake] detector not started (%s): listening without it\n", why);
        return false;
    }

    bool startFrontend() {
        // The settings microWakeWord's models were trained with
        FrontendConfig config;
        FrontendFillConfigWithDefaults(&config);
        config.window.size_ms = 30;
        config.window.step_size_ms = WAKE_FEATURE_STEP_MS;
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
        if (!FrontendPopulateState(&config, &_frontend, SAMPLE_RATE)) return fail("features");
        return true;
    }

    bool addOps() {
        const bool added =
            _resolver.AddCallOnce() == kTfLiteOk && _resolver.AddVarHandle() == kTfLiteOk &&
            _resolver.AddReshape() == kTfLiteOk && _resolver.AddReadVariable() == kTfLiteOk &&
            _resolver.AddStridedSlice() == kTfLiteOk &&
            _resolver.AddConcatenation() == kTfLiteOk &&
            _resolver.AddAssignVariable() == kTfLiteOk && _resolver.AddConv2D() == kTfLiteOk &&
            _resolver.AddMul() == kTfLiteOk && _resolver.AddAdd() == kTfLiteOk &&
            _resolver.AddMean() == kTfLiteOk && _resolver.AddFullyConnected() == kTfLiteOk &&
            _resolver.AddLogistic() == kTfLiteOk && _resolver.AddQuantize() == kTfLiteOk &&
            _resolver.AddDepthwiseConv2D() == kTfLiteOk &&
            _resolver.AddAveragePool2D() == kTfLiteOk &&
            _resolver.AddMaxPool2D() == kTfLiteOk && _resolver.AddPad() == kTfLiteOk &&
            _resolver.AddPack() == kTfLiteOk && _resolver.AddSplitV() == kTfLiteOk;
        return added || fail("operators");
    }

    /** One 10 ms slice of features; true on a detection. */
    bool slice(const uint16_t* values) {
        TfLiteTensor* input = _interpreter->input(0);
        int8_t* features = input->data.int8 + _filled * FEATURES;
        for (size_t i = 0; i < FEATURES; ++i) {
            // The frontend's uint16 scaled to int8, as TensorFlow's micro_speech example does
            constexpr int32_t scale = 256;
            constexpr int32_t divisor = 666;  // 25.6 * 26.0, rounded
            const int32_t value =
                ((static_cast<int32_t>(values[i]) * scale) + (divisor / 2)) / divisor - 128;
            features[i] = static_cast<int8_t>(value < -128 ? -128 : (value > 127 ? 127 : value));
        }
        if (++_filled < _stride) return false;
        _filled = 0;
        if (_interpreter->Invoke() != kTfLiteOk) return false;

        _probabilities[_next] = _interpreter->output(0)->data.uint8[0];
        _next = (_next + 1) % WAKE_SLIDING_WINDOW;
        uint32_t sum = 0;
        for (size_t i = 0; i < WAKE_SLIDING_WINDOW; ++i) sum += _probabilities[i];
        if (sum <= WAKE_PROBABILITY_CUTOFF * 255.0f * WAKE_SLIDING_WINDOW) return false;
        clearProbabilities();  // one utterance, one detection
        return true;
    }

    void clearProbabilities() {
        memset(_probabilities, 0, sizeof(_probabilities));
        _next = 0;
    }

    FrontendState _frontend = {};
    tflite::MicroMutableOpResolver<20> _resolver;
    tflite::MicroInterpreter* _interpreter = nullptr;
    uint8_t* _arena = nullptr;
    uint8_t* _variableArena = nullptr;
    size_t _arenaBytes = 0;
    int _stride = 0;
    int _filled = 0;
    uint8_t _probabilities[MAX_WINDOW] = {};
    size_t _next = 0;
    bool _ready = false;
};
