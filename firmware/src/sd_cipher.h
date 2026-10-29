#pragma once

#include <Arduino.h>
#include <Preferences.h>
#include <esp_random.h>
#include <mbedtls/aes.h>

#include "record_cipher.h"

/**
 * AES-256-CTR for the speech on the microSD (hardware AES through mbedtls). The key is 32
 * random bytes made on this device the first time and kept in its NVS: it never leaves the
 * device, so the card alone cannot be read elsewhere. Someone with the whole wearable can
 * read the flash: that is not covered (flash encryption is permanent on the ESP32-S3).
 *
 * begin() after the radio is on: esp_fill_random gives true random numbers only then.
 */
class AesCtrCipher : public RecordCipher {
public:
    ~AesCtrCipher() override {
        if (_ready) mbedtls_aes_free(&_aes);
    }

    /** Loads the key, making it the first time; false when NVS cannot keep it. */
    bool begin() {
        Preferences preferences;
        if (!preferences.begin(NAMESPACE, false)) return false;
        uint8_t key[KEY_SIZE];
        bool ok = true;
        if (preferences.getBytesLength(KEY_NAME) == KEY_SIZE) {
            ok = preferences.getBytes(KEY_NAME, key, KEY_SIZE) == KEY_SIZE;
        } else {
            esp_fill_random(key, KEY_SIZE);
            ok = preferences.putBytes(KEY_NAME, key, KEY_SIZE) == KEY_SIZE;
            if (ok) Serial.println("[SD] new key for the card made on this device");
        }
        preferences.end();
        if (ok) {
            mbedtls_aes_init(&_aes);
            ok = mbedtls_aes_setkey_enc(&_aes, key, KEY_SIZE * 8) == 0;
            if (ok) {
                _ready = true;
            } else {
                mbedtls_aes_free(&_aes);
            }
        }
        memset(key, 0, sizeof(key));
        return ok;
    }

    void newIv(uint8_t* iv) override { esp_fill_random(iv, IV_SIZE); }

    void start(const uint8_t* iv) override {
        memcpy(_counter, iv, IV_SIZE);
        memset(_block, 0, sizeof(_block));
        _offset = 0;
    }

    void apply(uint8_t* data, size_t length) override {
        mbedtls_aes_crypt_ctr(&_aes, length, &_offset, _counter, _block, data, data);
    }

private:
    static constexpr const char* NAMESPACE = "echo-sd";
    static constexpr const char* KEY_NAME = "key";
    static constexpr size_t KEY_SIZE = 32;

    mbedtls_aes_context _aes;
    bool _ready = false;
    uint8_t _counter[IV_SIZE] = {};
    uint8_t _block[IV_SIZE] = {};
    size_t _offset = 0;
};
