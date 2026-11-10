#pragma once

#include <Arduino.h>
#include <driver/i2s.h>
#include "config.h"

/**
 * Audio capture module for the XIAO ESP32-S3 Sense PDM microphone.
 *
 * Reads:
 * - PDM microphone
 * - converted internally by ESP32 I2S peripheral
 * - PCM 16-bit
 * - Mono
 * - 16kHz
 */

class AudioCapture {
public:
    bool begin();
    void end();

    /** The I2S driver is installed: off while muted or turning off, to save power. */
    bool isRunning() const { return _initialized; }

    /**
     * Read PCM samples from microphone
     *
     * @param buffer Output PCM buffer
     * @param samples Number of samples requested
     * @return Number of samples read, -1 on error
     */
    int readSamples(int16_t* buffer, size_t samples);

private:
    bool _initialized = false;
};


// ============================================================
// Initialize microphone
// ============================================================

bool AudioCapture::begin() {

    if (_initialized)
        return true;


    Serial.println("[Audio] Initializing PDM microphone...");


    i2s_config_t i2s_config = {
        .mode = (i2s_mode_t)(
            I2S_MODE_MASTER |
            I2S_MODE_RX |
            I2S_MODE_PDM
        ),

        .sample_rate = SAMPLE_RATE,

        .bits_per_sample =
            I2S_BITS_PER_SAMPLE_16BIT,

        .channel_format =
            I2S_CHANNEL_FMT_ONLY_LEFT,

        /*
         * PDM microphone does not use classic I2S framing.
         */
        .communication_format =
            I2S_COMM_FORMAT_STAND_MSB,


        .intr_alloc_flags =
            ESP_INTR_FLAG_LEVEL1,


        /*
         * DMA buffers
         */
        .dma_buf_count = 8,

        .dma_buf_len =
            PCM_BUFFER_SIZE,


        .use_apll = false,

        .tx_desc_auto_clear = false,

        .fixed_mclk = 0
    };


    i2s_pin_config_t pin_config = {

        /*
         * For XIAO ESP32-S3 Sense:
         *
         * GPIO42 -> PDM clock
         * GPIO41 -> PDM data
         */

        .bck_io_num =
            I2S_PIN_NO_CHANGE,

        .ws_io_num =
            I2S_WS_PIN,

        .data_out_num =
            I2S_PIN_NO_CHANGE,

        .data_in_num =
            I2S_DATA_PIN
    };


    esp_err_t err;


    // Install I2S driver
    err = i2s_driver_install(
        I2S_PORT,
        &i2s_config,
        0,
        nullptr
    );


    if (err != ESP_OK) {

        Serial.printf(
            "[Audio] I2S install failed: %d\n",
            err
        );

        return false;
    }



    // Attach pins
    err = i2s_set_pin(
        I2S_PORT,
        &pin_config
    );


    if (err != ESP_OK) {

        Serial.printf(
            "[Audio] I2S pin setup failed: %d\n",
            err
        );

        i2s_driver_uninstall(I2S_PORT);

        return false;
    }



    /*
     * Force clock configuration
     */
    err = i2s_set_clk(
        I2S_PORT,
        SAMPLE_RATE,
        I2S_BITS_PER_SAMPLE_16BIT,
        I2S_CHANNEL_MONO
    );


    if (err != ESP_OK) {

        Serial.printf(
            "[Audio] Clock setup failed: %d\n",
            err
        );

        i2s_driver_uninstall(I2S_PORT);

        return false;
    }



    /*
     * Warm-up reads.
     * First samples after enabling PDM are often garbage.
     */
    int16_t discard[PCM_BUFFER_SIZE];

    size_t bytes_read = 0;


    for (int i = 0; i < 5; i++) {

        i2s_read(
            I2S_PORT,
            discard,
            sizeof(discard),
            &bytes_read,
            portMAX_DELAY
        );
    }



    _initialized = true;


    Serial.println(
        "[Audio] PDM microphone initialized"
    );

    Serial.printf(
        "[Audio] Sample rate: %d Hz\n",
        SAMPLE_RATE
    );


    return true;
}



// ============================================================
// Stop microphone
// ============================================================

void AudioCapture::end() {

    if (_initialized) {

        i2s_driver_uninstall(
            I2S_PORT
        );

        _initialized = false;

        Serial.println(
            "[Audio] stopped"
        );
    }
}



// ============================================================
// Read microphone samples
// ============================================================

int AudioCapture::readSamples(
    int16_t* buffer,
    size_t samples
) {

    if (!_initialized)
        return -1;



    size_t bytes_to_read =
        samples * sizeof(int16_t);


    size_t bytes_read = 0;



    esp_err_t err =
        i2s_read(
            I2S_PORT,
            buffer,
            bytes_to_read,
            &bytes_read,
            pdMS_TO_TICKS(200)
        );



    if (err != ESP_OK) {

        Serial.printf(
            "[Audio] read error: %d\n",
            err
        );

        return -1;
    }



    return bytes_read / sizeof(int16_t);
}