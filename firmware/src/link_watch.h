#pragma once

#include <cstdint>

/**
 * Echo must never stay out of the phone's reach. With no phone linked it should be
 * advertising: if it is not (NimBLE did not restart it), it advertises again. A link that
 * never becomes ready (pairing or the app's setup stuck) is dropped, so the phone can try
 * again. Before this, either kept Echo silent until reset: 30 minutes lost on 2026-11-22.
 */
class LinkWatch {
public:
    enum class Action : uint8_t { NONE, ADVERTISE, DROP_LINK };

    /** Grace before advertising again: NimBLE restarts it itself right after a disconnect. */
    static constexpr uint32_t QUIET_MS = 3000;

    explicit LinkWatch(uint32_t stuckAfterMs) : _stuckAfterMs(stuckAfterMs) {}

    Action update(uint32_t nowMs, bool linked, bool ready, bool advertising) {
        if (linked && !ready) {
            _quiet = false;
            if (!_waiting) {
                _waiting = true;
                _sinceMs = nowMs;
            }
            if (nowMs - _sinceMs < _stuckAfterMs) return Action::NONE;
            _sinceMs = nowMs;
            return Action::DROP_LINK;
        }
        _waiting = false;
        if (linked || advertising) {
            _quiet = false;
            return Action::NONE;
        }
        if (!_quiet) {
            _quiet = true;
            _sinceMs = nowMs;
        }
        if (nowMs - _sinceMs < QUIET_MS) return Action::NONE;
        _sinceMs = nowMs;
        return Action::ADVERTISE;
    }

private:
    uint32_t _stuckAfterMs;
    uint32_t _sinceMs = 0;
    bool _waiting = false;
    bool _quiet = false;
};
