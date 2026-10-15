#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>

#include "ble_protocol.h"
#include "buffered_segment.h"

/**
 * One photo at a time, in RAM only: from TAKE_PHOTO until the app confirms the upload.
 * Nothing is written to flash; a reboot loses it.
 *
 * The Arduino loop requests a capture and later sends and frees the photo; the camera
 * task fills it. The state is the only shared field: the camera task writes the photo
 * fields before publishing READY, and the loop reads them only after seeing READY.
 *
 *   EMPTY -> REQUESTED (loop) -> CAPTURING (camera) -> READY | FAILED (camera)
 *   READY -> EMPTY (loop: upload confirmed, or discarded on mute)
 *   FAILED -> EMPTY (loop: failure reported)
 */
class PhotoSlot {
public:
    enum State : uint8_t { EMPTY, REQUESTED, CAPTURING, READY, FAILED };

    void attach(uint8_t* buffer, size_t capacity) {
        _buffer = buffer;
        _capacity = capacity;
    }

    bool hasBuffer() const { return _buffer != nullptr && _capacity > 0; }

    // --- Loop ---------------------------------------------------------------------

    /** TAKE_PHOTO: false while another photo is being taken or sent. */
    bool request() {
        if (!hasBuffer()) return false;
        uint8_t expected = EMPTY;
        return _state.compare_exchange_strong(expected, REQUESTED);
    }

    bool isReady() const { return _state.load() == READY; }

    /** No photo being taken or waiting to be sent. */
    bool isEmpty() const { return _state.load() == EMPTY; }

    /** The failure to report, once; the slot is free again. */
    bool takeFailure(uint8_t& reason) {
        uint8_t expected = FAILED;
        if (!_state.compare_exchange_strong(expected, EMPTY)) return false;
        reason = _failure;
        return true;
    }

    /** The photo as a buffered segment, for the BLE transfer (only when READY). */
    BufferedSegment segment() const {
        return {_segmentId, static_cast<uint32_t>(_length), 0, 0, _capturedAtMs, 0, _crc};
    }

    const uint8_t* data() const { return _buffer; }

    /** UPLOAD_OK for this photo: free the slot. */
    bool release(uint32_t segmentId) {
        if (_state.load() != READY || segmentId != _segmentId) return false;
        _state.store(EMPTY);
        return true;
    }

    /** Muted: drop a photo waiting to be taken or sent. A capture under way is not
     *  stopped; it becomes READY and is dropped on the next call. */
    bool discard() {
        uint8_t expected = REQUESTED;
        if (_state.compare_exchange_strong(expected, EMPTY)) return true;
        expected = READY;
        return _state.compare_exchange_strong(expected, EMPTY);
    }

    State state() const { return static_cast<State>(_state.load()); }

    // --- Camera task --------------------------------------------------------------

    /** False when the request was withdrawn (muted) meanwhile. */
    bool beginCapture() {
        uint8_t expected = REQUESTED;
        return _state.compare_exchange_strong(expected, CAPTURING);
    }

    uint8_t* buffer() { return _buffer; }
    size_t capacity() const { return _capacity; }

    void captureDone(size_t length, uint32_t capturedAtMs) {
        _length = length;
        _capturedAtMs = capturedAtMs;
        _crc = EchoBleProtocol::crc32(_buffer, length);
        _segmentId = EchoBleProtocol::PHOTO_SEGMENT_ID_FLAG | (++_counter & 0x7FFFFFFFU);
        _state.store(READY);
    }

    void captureFailed(uint8_t reason) {
        _failure = reason;
        _state.store(FAILED);
    }

private:
    std::atomic<uint8_t> _state{EMPTY};
    uint8_t* _buffer = nullptr;
    size_t _capacity = 0;
    size_t _length = 0;
    uint32_t _capturedAtMs = 0;
    uint32_t _crc = 0;
    uint32_t _segmentId = 0;
    uint32_t _counter = 0;
    uint8_t _failure = 0;
};
