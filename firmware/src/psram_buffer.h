#pragma once

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include "ble_protocol.h"
#include "config.h"
#include "ring_buffer_layout.h"

/**
 * Ring buffer on PSRAM for buffering audio segments awaiting BLE relay.
 */

struct BufferedSegment {
    uint32_t segmentId;
    uint32_t dataLength;
    uint32_t durationMs;
    uint32_t silenceBeforeMs;
    uint32_t capturedAtMs;
    uint16_t avgEnergy;
};

class PSRAMBuffer {
public:
    bool begin();

    /**
     * Store a segment in the buffer.
     * @return true if stored successfully, false if buffer full.
     */
    bool store(uint32_t segmentId, const uint8_t* data, size_t length,
               uint32_t durationMs, uint32_t silenceBeforeMs,
               uint32_t capturedAtMs, uint16_t avgEnergy);

    /**
     * Peek at the oldest buffered segment without removing it.
     * @param header Output: segment header.
     * @param data Output: pointer to ADPCM data (valid until next dequeue).
     * @return true if a segment is available.
     */
    bool peek(BufferedSegment& header, const uint8_t** data);

    /** Remove the oldest segment from the buffer. */
    void dequeue();

    /** Number of buffered segments. */
    uint16_t count() const;

    /** Check if buffer is empty. */
    bool isEmpty() const { return count() == 0; }

    /** Check if buffer has space for given data size. */
    bool hasSpace(size_t dataSize) const;

    /** Total bytes used in buffer. */
    size_t bytesUsed() const;

private:
    static constexpr size_t HEADER_SIZE = 22;

    uint8_t* _buffer = nullptr;
    RingBufferLayout _layout{PSRAM_BUFFER_SIZE};
    mutable SemaphoreHandle_t _mutex = nullptr;
    bool _initialized = false;
};

// Implementation

bool PSRAMBuffer::begin() {
    if (_initialized) return true;

    if (!psramFound()) {
        Serial.println("[Buffer] PSRAM not found!");
        return false;
    }

    _buffer = (uint8_t*)ps_malloc(PSRAM_BUFFER_SIZE);
    if (!_buffer) {
        Serial.println("[Buffer] Failed to allocate PSRAM buffer");
        return false;
    }

    _mutex = xSemaphoreCreateMutex();
    if (_mutex == nullptr) {
        free(_buffer);
        _buffer = nullptr;
        Serial.println("[Buffer] Failed to create buffer mutex");
        return false;
    }

    _layout = RingBufferLayout(PSRAM_BUFFER_SIZE);
    _initialized = true;

    Serial.printf("[Buffer] PSRAM buffer initialized: %u KB\n", PSRAM_BUFFER_SIZE / 1024);
    return true;
}

bool PSRAMBuffer::hasSpace(size_t dataSize) const {
    if (!_initialized || dataSize > PSRAM_BUFFER_SIZE - HEADER_SIZE) return false;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    const bool available = HEADER_SIZE + dataSize <= PSRAM_BUFFER_SIZE - _layout.bytesUsed();
    xSemaphoreGive(_mutex);
    return available;
}

uint16_t PSRAMBuffer::count() const {
    if (!_initialized) return 0;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    const uint16_t value = _layout.count();
    xSemaphoreGive(_mutex);
    return value;
}

size_t PSRAMBuffer::bytesUsed() const {
    if (!_initialized) return 0;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    const size_t value = _layout.bytesUsed();
    xSemaphoreGive(_mutex);
    return value;
}

bool PSRAMBuffer::store(uint32_t segmentId, const uint8_t* data, size_t length,
                        uint32_t durationMs, uint32_t silenceBeforeMs,
                        uint32_t capturedAtMs, uint16_t avgEnergy) {
    if (!_initialized || data == nullptr || length > UINT32_MAX || !hasSpace(length)) {
        return false;
    }

    const size_t entrySize = HEADER_SIZE + length;
    size_t offset = 0;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    if (!_layout.reserve(entrySize, offset)) {
        xSemaphoreGive(_mutex);
        return false;
    }

    EchoBleProtocol::writeU32(_buffer + offset, segmentId);
    EchoBleProtocol::writeU32(_buffer + offset + 4, static_cast<uint32_t>(length));
    EchoBleProtocol::writeU32(_buffer + offset + 8, durationMs);
    EchoBleProtocol::writeU32(_buffer + offset + 12, silenceBeforeMs);
    EchoBleProtocol::writeU32(_buffer + offset + 16, capturedAtMs);
    EchoBleProtocol::writeU16(_buffer + offset + 20, avgEnergy);
    memcpy(_buffer + offset + HEADER_SIZE, data, length);
    const uint16_t bufferedCount = _layout.count();
    xSemaphoreGive(_mutex);

    Serial.printf("[Buffer] Stored segment %lu: %u bytes (buffered: %u)\n",
                  static_cast<unsigned long>(segmentId), length, bufferedCount);
    return true;
}

bool PSRAMBuffer::peek(BufferedSegment& header, const uint8_t** data) {
    if (!_initialized || _layout.count() == 0 || data == nullptr) return false;

    xSemaphoreTake(_mutex, portMAX_DELAY);
    if (_layout.count() == 0) {
        xSemaphoreGive(_mutex);
        return false;
    }
    const size_t offset = _layout.frontOffset();
    header.segmentId = EchoBleProtocol::readU32(_buffer + offset);
    header.dataLength = EchoBleProtocol::readU32(_buffer + offset + 4);
    header.durationMs = EchoBleProtocol::readU32(_buffer + offset + 8);
    header.silenceBeforeMs = EchoBleProtocol::readU32(_buffer + offset + 12);
    header.capturedAtMs = EchoBleProtocol::readU32(_buffer + offset + 16);
    header.avgEnergy = EchoBleProtocol::readU16(_buffer + offset + 20);
    *data = _buffer + offset + HEADER_SIZE;
    xSemaphoreGive(_mutex);
    return true;
}

void PSRAMBuffer::dequeue() {
    if (!_initialized) return;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    if (_layout.count() == 0) {
        xSemaphoreGive(_mutex);
        return;
    }

    const size_t offset = _layout.frontOffset();
    const uint32_t segmentId = EchoBleProtocol::readU32(_buffer + offset);
    const uint32_t dataLength = EchoBleProtocol::readU32(_buffer + offset + 4);
    _layout.pop(HEADER_SIZE + dataLength);
    const uint16_t bufferedCount = _layout.count();
    xSemaphoreGive(_mutex);
    Serial.printf("[Buffer] Dequeued segment %lu (remaining: %u)\n",
                  static_cast<unsigned long>(segmentId), bufferedCount);
}
