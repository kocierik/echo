#pragma once

#include <cstdint>

/**
 * The wearable's button, read by polling: a short press or a long press.
 *
 * The level is debounced first. A long press fires as soon as it has been held for
 * `longPressMs` (the user feels it happen without letting go); releasing it then does
 * nothing more. Releasing earlier is a short press.
 */
class ButtonGesture {
public:
    enum Event : uint8_t { NONE, SHORT_PRESS, LONG_PRESS };

    ButtonGesture(uint32_t debounceMs, uint32_t longPressMs)
        : _debounceMs(debounceMs), _longPressMs(longPressMs) {}

    /** `pressed`: the raw level now (true = held down). */
    Event update(bool pressed, uint32_t nowMs) {
        if (pressed != _raw) {
            _raw = pressed;
            _rawChangedAtMs = nowMs;
        }
        if (_raw != _stable && static_cast<uint32_t>(nowMs - _rawChangedAtMs) >= _debounceMs) {
            _stable = _raw;
            if (_stable) {
                _pressedAtMs = _rawChangedAtMs;
                _longFired = false;
            } else if (!_longFired) {
                return SHORT_PRESS;
            }
        }
        if (_stable && !_longFired &&
            static_cast<uint32_t>(nowMs - _pressedAtMs) >= _longPressMs) {
            _longFired = true;
            return LONG_PRESS;
        }
        return NONE;
    }

private:
    uint32_t _debounceMs;
    uint32_t _longPressMs;
    bool _raw = false;
    bool _stable = false;
    bool _longFired = false;
    uint32_t _rawChangedAtMs = 0;
    uint32_t _pressedAtMs = 0;
};
