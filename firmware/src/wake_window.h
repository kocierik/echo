#pragma once

#include <cstdint>

/**
 * The pendant's wake word detection counts only in the opening of a segment, as the
 * server's rule wants the name among the first words; once per segment. A detection
 * outside a segment, or late in one, is ignored. Times are millis(), wrap included.
 */
class WakeWindow {
public:
    explicit WakeWindow(uint32_t windowMs) : _windowMs(windowMs) {}

    /** A segment starts at `startedMs` (its pre-buffer included). */
    void segmentStarted(uint32_t startedMs) {
        _open = true;
        _startedMs = startedMs;
        _heard = false;
    }

    /** Finalized or discarded: nothing carries over to the next segment. */
    void segmentEnded() {
        _open = false;
        _heard = false;
    }

    /** True once per segment, when the name was detected in its opening. */
    bool heard(bool detected, uint32_t nowMs) {
        if (!detected || !_open || _heard) return false;
        if (nowMs - _startedMs > _windowMs) return false;
        _heard = true;
        return true;
    }

    bool segmentHeard() const { return _open && _heard; }

private:
    uint32_t _windowMs;
    uint32_t _startedMs = 0;
    bool _open = false;
    bool _heard = false;
};
