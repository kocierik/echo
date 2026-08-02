#pragma once

#include <cstdint>

class BleBurstDecision {
public:
    static constexpr uint32_t BURST_BUDGET_US = 3000;
    static constexpr uint8_t MAX_NOTIFICATIONS_PER_UPDATE = 4;

    static bool beforeDeadline(uint32_t nowUs, uint32_t deadlineUs) {
        return static_cast<int32_t>(nowUs - deadlineUs) < 0;
    }

    static bool shouldContinue(bool notificationSucceeded, bool canSend,
                               uint32_t elapsedUs, uint8_t notificationsSent) {
        return notificationSucceeded && canSend &&
               elapsedUs < BURST_BUDGET_US &&
               notificationsSent < MAX_NOTIFICATIONS_PER_UPDATE;
    }
};

class BleTransferState {
public:
    enum Phase {
        IDLE,
        WAITING_READY,
        SENDING_WINDOW,
        WAITING_ACK,
        WAITING_UPLOAD,
        RESTARTING,
    };

    static constexpr uint16_t WINDOW_SIZE = 32;
    static constexpr uint32_t ACK_TIMEOUT_MS = 5000;

    void beginSegment(uint32_t segmentId, uint16_t totalChunks, uint32_t nowMs) {
        _segmentId = segmentId;
        _totalChunks = totalChunks;
        _nextSequence = 0;
        _windowStart = 0;
        _deadlineMs = nowMs + ACK_TIMEOUT_MS;
        _phase = _ready ? SENDING_WINDOW : WAITING_READY;
    }

    void onReady() {
        _ready = true;
        if (_phase == WAITING_READY) _phase = SENDING_WINDOW;
    }

    void onDisconnected() {
        _ready = false;
        _phase = IDLE;
        _segmentId = 0;
        _totalChunks = 0;
        _nextSequence = 0;
    }

    bool canSend(uint32_t) const { return _phase == SENDING_WINDOW; }

    void onChunkSent(uint16_t sequence, uint32_t nowMs) {
        if (_phase != SENDING_WINDOW || sequence != _nextSequence || sequence >= _totalChunks) return;
        ++_nextSequence;
        const bool windowComplete = (_nextSequence - _windowStart) >= WINDOW_SIZE;
        if (windowComplete || _nextSequence == _totalChunks) {
            _phase = WAITING_ACK;
            _deadlineMs = nowMs + ACK_TIMEOUT_MS;
        }
    }

    bool onAckWindow(uint32_t segmentId, uint16_t highestSequence, uint32_t) {
        if (_phase != WAITING_ACK || segmentId != _segmentId || _nextSequence == 0 ||
            highestSequence != static_cast<uint16_t>(_nextSequence - 1)) {
            return false;
        }
        if (_nextSequence == _totalChunks) {
            _phase = WAITING_UPLOAD;
        } else {
            _windowStart = _nextSequence;
            _phase = SENDING_WINDOW;
        }
        return true;
    }

    bool onRestartSegment(uint32_t segmentId) {
        if (_phase == IDLE || segmentId != _segmentId) return false;
        _phase = RESTARTING;
        return true;
    }

    bool update(uint32_t nowMs) {
        if (_phase == WAITING_ACK && static_cast<int32_t>(nowMs - _deadlineMs) >= 0) {
            _phase = RESTARTING;
            return true;
        }
        return false;
    }

    void restartComplete(uint32_t nowMs) {
        if (_phase != RESTARTING) return;
        _nextSequence = 0;
        _windowStart = 0;
        _deadlineMs = nowMs + ACK_TIMEOUT_MS;
        _phase = _ready ? SENDING_WINDOW : WAITING_READY;
    }

    bool canAcceptUploadOk(uint32_t segmentId) const {
        return _phase == WAITING_UPLOAD && segmentId == _segmentId &&
               _nextSequence == _totalChunks;
    }

    void uploadAccepted() {
        if (_phase == WAITING_UPLOAD) _phase = IDLE;
    }

    Phase phase() const { return _phase; }
    uint32_t segmentId() const { return _segmentId; }
    uint16_t nextSequence() const { return _nextSequence; }
    bool isReady() const { return _ready; }

private:
    Phase _phase = IDLE;
    uint32_t _segmentId = 0;
    uint16_t _totalChunks = 0;
    uint16_t _nextSequence = 0;
    uint16_t _windowStart = 0;
    uint32_t _deadlineMs = 0;
    bool _ready = false;
};