#pragma once

#include <cstdint>

/**
 * The wearable's button, read by polling: a short, a long or a very long press.
 *
 * The level is debounced first. Released before `longPressMs`: a short press (a photo).
 * Released between `longPressMs` and `veryLongPressMs`: a long press (mute), on release, so
 * holding on towards the very long press never mutes first. Held for `veryLongPressMs`: a
 * very long press (turn off), as soon as it is reached; releasing it then does nothing more.
 */
class ButtonGesture {
public:
    enum Event : uint8_t { NONE, SHORT_PRESS, LONG_PRESS, VERY_LONG_PRESS };

    ButtonGesture(uint32_t debounceMs, uint32_t longPressMs, uint32_t veryLongPressMs)
        : _debounceMs(debounceMs), _longPressMs(longPressMs), _veryLongPressMs(veryLongPressMs) {}

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
                _veryLongFired = false;
            } else if (!_veryLongFired) {
                const uint32_t heldMs = static_cast<uint32_t>(_rawChangedAtMs - _pressedAtMs);
                return heldMs >= _longPressMs ? LONG_PRESS : SHORT_PRESS;
            }
        }
        if (_stable && !_veryLongFired &&
            static_cast<uint32_t>(nowMs - _pressedAtMs) >= _veryLongPressMs) {
            _veryLongFired = true;
            return VERY_LONG_PRESS;
        }
        return NONE;
    }

private:
    uint32_t _debounceMs;
    uint32_t _longPressMs;
    uint32_t _veryLongPressMs;
    bool _raw = false;
    bool _stable = false;
    bool _veryLongFired = false;
    uint32_t _rawChangedAtMs = 0;
    uint32_t _pressedAtMs = 0;
};