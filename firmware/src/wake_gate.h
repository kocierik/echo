#pragma once

#include <cstdint>

/**
 * Off, a press wakes the chip, but only a hold turns Echo on: a brush in a pocket
 * goes back to sleep. Times are from the wake, which the press itself caused.
 */
class WakeGate {
public:
    enum class Decision : uint8_t { WAIT, BOOT, SLEEP };

    WakeGate(uint32_t holdMs, uint32_t debounceMs) : _holdMs(holdMs), _debounceMs(debounceMs) {}

    Decision update(bool pressed, uint32_t sinceWakeMs) {
        if (pressed) {
            _released = false;
            return sinceWakeMs >= _holdMs ? Decision::BOOT : Decision::WAIT;
        }
        if (!_released) {
            _released = true;
            _releasedAtMs = sinceWakeMs;
        }
        return sinceWakeMs - _releasedAtMs >= _debounceMs ? Decision::SLEEP : Decision::WAIT;
    }

private:
    uint32_t _holdMs;
    uint32_t _debounceMs;
    bool _released = false;
    uint32_t _releasedAtMs = 0;
};
