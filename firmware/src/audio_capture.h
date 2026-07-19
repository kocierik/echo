#pragma once

#include <driver/i2s.h>
#include "config.h"

/**
 * Audio capture module for the XIAO ESP32-S3 Sense PDM microphone.
 * Reads PCM samples at 16kHz, 16-bit, mono via I2S.
 */

class AudioCapture {
public:
    bool begin();
    void end();

    /**
     * Read a frame of PCM samples from the microphone.
     * @param buffer Output buffer for 16-bit PCM samples.
     * @param samples Number of samples to read.
     * @return Number of samples actually read, or -1 on error.
     */
    int readSamples(int16_t* buffer, size_t samples);

private:
    bool _initialized = false;
};

// Implementation

bool AudioCapture::begin() {
    if (_initialized) return true;

    i2s_config_t i2s_config = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_PDM),
        .sample_rate = SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 4,
        .dma_buf_len = PCM_BUFFER_SIZE,
        .use_apll = false,
        .tx_desc_auto_clear = false,
        .fixed_mclk = 0,
    };

    i2s_pin_config_t pin_config = {
        .bck_io_num = I2S_PIN_NO_CHANGE,
        .ws_io_num = I2S_WS_PIN,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num = I2S_DATA_PIN,
    };

    esp_err_t err = i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
    if (err != ESP_OK) {
        Serial.printf("[Audio] I2S driver install failed: %d\n", err);
        return false;
    }

    err = i2s_set_pin(I2S_PORT, &pin_config);
    if (err != ESP_OK) {
        Serial.printf("[Audio] I2S set pin failed: %d\n", err);
        i2s_driver_uninstall(I2S_PORT);
        return false;
    }

    // Warm up - discard first few reads (they can be noisy)
    int16_t discard[PCM_BUFFER_SIZE];
    size_t bytes_read;
    for (int i = 0; i < 3; i++) {
        i2s_read(I2S_PORT, discard, sizeof(discard), &bytes_read, portMAX_DELAY);
    }

    _initialized = true;
    Serial.println("[Audio] I2S initialized - 16kHz, 16-bit, mono PDM");
    return true;
}

void AudioCapture::end() {
    if (_initialized) {
        i2s_driver_uninstall(I2S_PORT);
        _initialized = false;
        Serial.println("[Audio] I2S stopped");
    }
}

int AudioCapture::readSamples(int16_t* buffer, size_t samples) {
    if (!_initialized) return -1;

    size_t bytes_to_read = samples * sizeof(int16_t);
    size_t bytes_read = 0;

    esp_err_t err = i2s_read(I2S_PORT, buffer, bytes_to_read, &bytes_read, pdMS_TO_TICKS(100));
    if (err != ESP_OK) {
        return -1;
    }

    return bytes_read / sizeof(int16_t);
}
