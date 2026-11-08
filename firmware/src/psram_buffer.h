#pragma once

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include "ble_protocol.h"
#include "buffered_segment.h"
#include "buffer_sizing.h"
#include "config.h"
#include "ring_buffer_layout.h"

/**
 * Ring buffer on PSRAM for buffering audio segments awaiting BLE relay.
 */

class PSRAMBuffer {
public:
    /** Takes up to PSRAM_BUFFER_SIZE, leaving PSRAM_RESERVE free; call it after the other
     *  PSRAM allocations of setup(). */
    bool begin();

    /** Bytes the buffer can hold (decided at begin()). */
    size_t capacity() const { return _capacity; }

    /**
     * Store a segment in the buffer.
     * @return true if stored successfully, false if buffer full.
     */
    bool store(uint32_t segmentId, const uint8_t* data, size_t length,
               uint32_t durationMs, uint32_t silenceBeforeMs,
               uint32_t capturedAtMs, uint16_t avgEnergy, uint32_t crc);

    /**
     * Peek at the oldest buffered segment without removing it.
     * @param header Output: segment header.
     * @param data Output: pointer to the encoded speech (valid until next dequeue).
     * @return true if a segment is available.
     */
    bool peek(BufferedSegment& header, const uint8_t** data);

    /** Remove the oldest segment from the buffer. */
    void dequeue();

    /** Drop the oldest segment and return its ID, or 0 when empty. */
    uint32_t dropOldest();

    /** Cumulative number of segments dropped due to overflow. */
    uint32_t droppedSegmentCount() const;

    /** Number of buffered segments. */
    uint16_t count() const;

    /** Check if buffer is empty. */
    bool isEmpty() const { return count() == 0; }

    /** Check if buffer has space for given data size. */
    bool hasSpace(size_t dataSize) const;

    /** Total bytes used in buffer. */
    size_t bytesUsed() const;

private:
    static constexpr size_t HEADER_SIZE = BufferedSegmentCodec::HEADER_SIZE;

    uint8_t* _buffer = nullptr;
    size_t _capacity = 0;
    RingBufferLayout _layout{0};
    mutable SemaphoreHandle_t _mutex = nullptr;
    uint32_t _droppedSegmentCount = 0;
    bool _initialized = false;
};

// Implementation

bool PSRAMBuffer::begin() {
    if (_initialized) return true;

    if (!psramFound()) {
        Serial.println("[Buffer] PSRAM not found!");
        return false;
    }

    _capacity = chooseBufferCapacity(
        PSRAM_BUFFER_SIZE,
        heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM),
        PSRAM_RESERVE,
        SEGMENT_MAX_SIZE * 2);
    _buffer = _capacity > 0 ? (uint8_t*)ps_malloc(_capacity) : nullptr;
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

    _layout = RingBufferLayout(_capacity);
    _initialized = true;

    Serial.printf("[Buffer] PSRAM buffer initialized: %u KB (~%u min of speech)\n",
                  static_cast<unsigned>(_capacity / 1024),
                  static_cast<unsigned>(_capacity / (8 * 1024) / 60));
    return true;
}

bool PSRAMBuffer::hasSpace(size_t dataSize) const {
    if (!_initialized || dataSize > _capacity - HEADER_SIZE) return false;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    const bool available = HEADER_SIZE + dataSize <= _capacity - _layout.bytesUsed();
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
                        uint32_t capturedAtMs, uint16_t avgEnergy, uint32_t crc) {
    if (!_initialized || data == nullptr || length > UINT32_MAX ||
        length > _capacity - HEADER_SIZE) {
        return false;
    }

    const size_t entrySize = HEADER_SIZE + length;
    size_t offset = 0;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    if (!_layout.reserve(entrySize, offset)) {
        xSemaphoreGive(_mutex);
        return false;
    }

    const BufferedSegment header = {
        segmentId,
        static_cast<uint32_t>(length),
        durationMs,
        silenceBeforeMs,
        capturedAtMs,
        avgEnergy,
        crc,
    };
    BufferedSegmentCodec::encode(header, _buffer + offset);
    memcpy(_buffer + offset + HEADER_SIZE, data, length);
    const uint16_t bufferedCount = _layout.count();
    xSemaphoreGive(_mutex);

    Serial.printf("[Buffer] Stored segment %lu: %u bytes (buffered: %u)\n",
                  static_cast<unsigned long>(segmentId), length, bufferedCount);
    return true;
}

bool PSRAMBuffer::peek(BufferedSegment& header, const uint8_t** data) {
    if (!_initialized || data == nullptr) return false;

    xSemaphoreTake(_mutex, portMAX_DELAY);
    if (_layout.count() == 0) {
        xSemaphoreGive(_mutex);
        return false;
    }
    const size_t offset = _layout.frontOffset();
    header = BufferedSegmentCodec::decode(_buffer + offset);
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
    const BufferedSegment header = BufferedSegmentCodec::decode(_buffer + offset);
    _layout.pop(HEADER_SIZE + header.dataLength);
    const uint16_t bufferedCount = _layout.count();
    xSemaphoreGive(_mutex);
    Serial.printf("[Buffer] Dequeued segment %lu (remaining: %u)\n",
                  static_cast<unsigned long>(header.segmentId), bufferedCount);
}

uint32_t PSRAMBuffer::dropOldest() {
    if (!_initialized) return 0;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    if (_layout.count() == 0) {
        xSemaphoreGive(_mutex);
        return 0;
    }

    const size_t offset = _layout.frontOffset();
    const BufferedSegment header = BufferedSegmentCodec::decode(_buffer + offset);
    _layout.pop(HEADER_SIZE + header.dataLength);
    ++_droppedSegmentCount;
    const uint16_t bufferedCount = _layout.count();
    const uint32_t droppedCount = _droppedSegmentCount;
    xSemaphoreGive(_mutex);

    Serial.printf("[Buffer] Dropped oldest segment %lu (remaining: %u, dropped: %lu)\n",
                  static_cast<unsigned long>(header.segmentId), bufferedCount,
                  static_cast<unsigned long>(droppedCount));
    return header.segmentId;
}

uint32_t PSRAMBuffer::droppedSegmentCount() const {
    if (!_initialized) return 0;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    const uint32_t value = _droppedSegmentCount;
    xSemaphoreGive(_mutex);
    return value;
}
