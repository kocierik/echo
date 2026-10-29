#pragma once

#include <Arduino.h>
#include <SD.h>
#include <SPI.h>

#include "config.h"
#include "segment_log.h"

/**
 * The microSD card on the XIAO ESP32-S3 Sense, for SegmentLog: SPI with CS GPIO21 (the
 * LED's pin: Indicators::release() first), SCK GPIO7, MISO GPIO8, MOSI GPIO9. FAT32, up
 * to 32 GB. Every write is flushed before it returns, so a power cut loses at most the
 * record being written.
 */
class SdStorage : public LogStorage {
public:
    /** Mounts the card and makes the queue folder; false without a usable card. */
    bool begin() {
        SPI.begin(SD_SCK_PIN, SD_MISO_PIN, SD_MOSI_PIN, SD_CS_PIN);
        if (!SD.begin(SD_CS_PIN, SPI, SD_SPI_HZ)) {
            Serial.println("[SD] no card");
            return false;
        }
        if (SD.cardType() == CARD_NONE) {
            Serial.println("[SD] no card");
            return false;
        }
        if (!SD.exists("/echo")) SD.mkdir("/echo");
        if (!SD.exists("/echo/q")) SD.mkdir("/echo/q");
        if (!SD.exists(SD_SEALED_FOLDER)) SD.mkdir(SD_SEALED_FOLDER);
        _mounted = true;
        Serial.printf("[SD] card %llu MB, %llu MB free\n",
                      static_cast<unsigned long long>(SD.totalBytes() / (1024 * 1024)),
                      static_cast<unsigned long long>(freeBytes() / (1024 * 1024)));
        return true;
    }

    bool mounted() const { return _mounted; }

    bool append(const char* path, const uint8_t* data, size_t length) override {
        File file = SD.open(path, FILE_APPEND);
        if (!file) return false;
        const size_t written = file.write(data, length);
        file.flush();
        file.close();
        return written == length;
    }

    long size(const char* path) override {
        if (!SD.exists(path)) return -1;
        File file = SD.open(path, FILE_READ);
        if (!file) return -1;
        const long length = static_cast<long>(file.size());
        file.close();
        return length;
    }

    size_t read(const char* path, size_t offset, uint8_t* out, size_t length) override {
        File file = SD.open(path, FILE_READ);
        if (!file) return 0;
        size_t got = 0;
        if (file.seek(offset)) got = file.read(out, length);
        file.close();
        return got;
    }

    bool remove(const char* path) override { return SD.remove(path); }

    bool replace(const char* path, const uint8_t* data, size_t length) override {
        File file = SD.open(path, FILE_WRITE);  // truncates
        if (!file) return false;
        const size_t written = file.write(data, length);
        file.flush();
        file.close();
        return written == length;
    }

    uint64_t totalBytes() override { return SD.totalBytes(); }

    uint64_t freeBytes() override {
        const uint64_t total = SD.totalBytes();
        const uint64_t used = SD.usedBytes();
        return used >= total ? 0 : total - used;
    }

private:
    bool _mounted = false;
};
