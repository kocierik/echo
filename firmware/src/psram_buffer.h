#pragma once

#include <Arduino.h>
#include "config.h"

/**
 * Ring buffer on PSRAM for buffering audio segments when WiFi is unavailable.
 * Stores complete ADPCM segments with metadata for later transmission.
 */

struct BufferedSegment {
    uint32_t dataLength;
    uint32_t durationMs;
    uint32_t silenceBeforeMs;
    char recordedAt[30];
    // Followed by dataLength bytes of ADPCM data
};

class PSRAMBuffer {
public:
    bool begin();

    /**
     * Store a segment in the buffer.
     * @return true if stored successfully, false if buffer full.
     */
    bool store(const uint8_t* data, size_t length, uint32_t durationMs,
               uint32_t silenceBeforeMs, const char* recordedAt);

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
    uint16_t count() const { return _count; }

    /** Check if buffer is empty. */
    bool isEmpty() const { return _count == 0; }

    /** Check if buffer has space for given data size. */
    bool hasSpace(size_t dataSize) const;

    /** Total bytes used in buffer. */
    size_t bytesUsed() const { return _writePos >= _readPos ?
                               _writePos - _readPos :
                               PSRAM_BUFFER_SIZE - _readPos + _writePos; }

private:
    uint8_t* _buffer = nullptr;
    size_t _readPos = 0;
    size_t _writePos = 0;
    uint16_t _count = 0;
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

    _readPos = 0;
    _writePos = 0;
    _count = 0;
    _initialized = true;

    Serial.printf("[Buffer] PSRAM buffer initialized: %u KB\n", PSRAM_BUFFER_SIZE / 1024);
    return true;
}

bool PSRAMBuffer::hasSpace(size_t dataSize) const {
    size_t needed = sizeof(BufferedSegment) + dataSize;
    size_t available = (_readPos <= _writePos) ?
                       PSRAM_BUFFER_SIZE - _writePos + _readPos :
                       _readPos - _writePos;
    return available > needed + 64;  // Leave some margin
}

bool PSRAMBuffer::store(const uint8_t* data, size_t length, uint32_t durationMs,
                        uint32_t silenceBeforeMs, const char* recordedAt) {
    if (!_initialized || !hasSpace(length)) {
        return false;
    }

    size_t entrySize = sizeof(BufferedSegment) + length;

    // Simple linear write (wrap if needed)
    if (_writePos + entrySize > PSRAM_BUFFER_SIZE) {
        // Not enough contiguous space at end, wrap to beginning
        if (_readPos < entrySize + 64) {
            return false;  // Not enough space at beginning either
        }
        _writePos = 0;
    }

    // Write header
    BufferedSegment* header = (BufferedSegment*)(_buffer + _writePos);
    header->dataLength = length;
    header->durationMs = durationMs;
    header->silenceBeforeMs = silenceBeforeMs;
    strncpy(header->recordedAt, recordedAt, sizeof(header->recordedAt) - 1);
    header->recordedAt[sizeof(header->recordedAt) - 1] = '\0';

    // Write data
    memcpy(_buffer + _writePos + sizeof(BufferedSegment), data, length);
    _writePos += entrySize;
    _count++;

    Serial.printf("[Buffer] Stored segment: %u bytes (buffered: %u)\n", length, _count);
    return true;
}

bool PSRAMBuffer::peek(BufferedSegment& header, const uint8_t** data) {
    if (!_initialized || _count == 0) return false;

    BufferedSegment* stored = (BufferedSegment*)(_buffer + _readPos);
    header = *stored;
    *data = _buffer + _readPos + sizeof(BufferedSegment);
    return true;
}

void PSRAMBuffer::dequeue() {
    if (!_initialized || _count == 0) return;

    BufferedSegment* stored = (BufferedSegment*)(_buffer + _readPos);
    size_t entrySize = sizeof(BufferedSegment) + stored->dataLength;
    _readPos += entrySize;
    _count--;

    if (_count == 0) {
        _readPos = 0;
        _writePos = 0;
    }

    Serial.printf("[Buffer] Dequeued segment (remaining: %u)\n", _count);
}
