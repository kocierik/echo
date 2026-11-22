#pragma once

#include <Arduino.h>
#include <esp_camera.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "config.h"
#include "photo_slot.h"

/**
 * The camera, powered only while a photo is taken.
 *
 * The XIAO Sense does not wire the sensor's power-down pin, so the driver is started
 * for each photo and stopped after it: the sensor draws nothing between photos. The
 * capture runs in its own task on core 0, so the audio loop on core 1 never waits for
 * it (sensor start-up and the exposure warm-up take hundreds of milliseconds).
 */
class CameraCapture {
public:
    /** Probes the sensor once; false (and no task) when no camera is connected. */
    bool begin(PhotoSlot& slot) {
        _slot = &slot;
        if (!slot.hasBuffer()) return false;
        if (!start()) {
            Serial.println("[Camera] no camera found");
            return false;
        }
        sensor_t* sensor = esp_camera_sensor_get();
        Serial.printf("[Camera] sensor PID=0x%04x\n", sensor != nullptr ? sensor->id.PID : 0);
        stop();
        _available = xTaskCreatePinnedToCore(
            taskEntry, "camera", 4096, this, 1, &_task, 0) == pdPASS;
        return _available;
    }

    bool isAvailable() const { return _available; }

    /** Takes the photo the slot was just reserved for. */
    void trigger() {
        if (_task != nullptr) xTaskNotifyGive(_task);
    }

private:
    static void taskEntry(void* self) { static_cast<CameraCapture*>(self)->run(); }

    void run() {
        for (;;) {
            ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
            if (!_slot->beginCapture()) continue;  // withdrawn (muted) meanwhile
            capture();
        }
    }

    void capture() {
        const uint32_t startedMs = millis();
        if (!start()) {
            _slot->captureFailed(EchoBleProtocol::PHOTO_FAILED_CAPTURE);
            return;
        }
        for (int i = 0; i < PHOTO_WARMUP_FRAMES; ++i) {
            camera_fb_t* warmup = esp_camera_fb_get();
            if (warmup != nullptr) esp_camera_fb_return(warmup);
        }
        camera_fb_t* frame = esp_camera_fb_get();
        const uint32_t capturedAtMs = millis();
        size_t length = 0;
        if (frame != nullptr && frame->format == PIXFORMAT_JPEG &&
            frame->len <= _slot->capacity()) {
            memcpy(_slot->buffer(), frame->buf, frame->len);
            length = frame->len;
        }
        if (frame != nullptr) esp_camera_fb_return(frame);
        stop();

        if (length == 0) {
            Serial.println("[Camera] capture failed");
            _slot->captureFailed(EchoBleProtocol::PHOTO_FAILED_CAPTURE);
            return;
        }
        _slot->captureDone(length, capturedAtMs);
        Serial.printf("[Camera] photo %u bytes in %u ms\n",
                      static_cast<unsigned>(length),
                      static_cast<unsigned>(capturedAtMs - startedMs));
    }

    static bool start() {
        camera_config_t config = {};
        config.pin_pwdn = CAM_PIN_PWDN;
        config.pin_reset = CAM_PIN_RESET;
        config.pin_xclk = CAM_PIN_XCLK;
        config.pin_sccb_sda = CAM_PIN_SIOD;
        config.pin_sccb_scl = CAM_PIN_SIOC;
        config.pin_d7 = CAM_PIN_D7;
        config.pin_d6 = CAM_PIN_D6;
        config.pin_d5 = CAM_PIN_D5;
        config.pin_d4 = CAM_PIN_D4;
        config.pin_d3 = CAM_PIN_D3;
        config.pin_d2 = CAM_PIN_D2;
        config.pin_d1 = CAM_PIN_D1;
        config.pin_d0 = CAM_PIN_D0;
        config.pin_vsync = CAM_PIN_VSYNC;
        config.pin_href = CAM_PIN_HREF;
        config.pin_pclk = CAM_PIN_PCLK;
        config.xclk_freq_hz = 20000000;
        config.ledc_timer = LEDC_TIMER_0;
        config.ledc_channel = LEDC_CHANNEL_0;
        config.pixel_format = PIXFORMAT_JPEG;
        config.frame_size = PHOTO_FRAME_SIZE;
        config.jpeg_quality = PHOTO_JPEG_QUALITY;
        config.fb_count = 1;
        config.fb_location = CAMERA_FB_IN_PSRAM;
        config.grab_mode = CAMERA_GRAB_LATEST;
        if (esp_camera_init(&config) != ESP_OK) return false;
        sensor_t* sensor = esp_camera_sensor_get();
        if (sensor != nullptr) {
            // The Sense board's sensor reads left and right swapped: photos came mirrored
            sensor->set_hmirror(sensor, 1);
            // In dim light, more gain rather than a longer exposure (less blur), and the
            // exposure a step brighter: photos came dark
            sensor->set_gainceiling(sensor, GAINCEILING_16X);
            sensor->set_ae_level(sensor, 1);
            // Photos in warm, dim rooms came magenta: automatic white balance with its
            // gains applied, and the lens correction that evens out the colour towards the
            // corners, set explicitly rather than left to the driver's defaults
            sensor->set_whitebal(sensor, 1);
            sensor->set_awb_gain(sensor, 1);
            sensor->set_wb_mode(sensor, 0);
            sensor->set_lenc(sensor, 1);
        }
        return true;
    }

    static void stop() { esp_camera_deinit(); }

    PhotoSlot* _slot = nullptr;
    TaskHandle_t _task = nullptr;
    bool _available = false;
};
