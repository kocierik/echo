#pragma once

#include <cstdint>

class ButtonDebouncer {
public:
    ButtonDebouncer(bool initialState, uint32_t debounceMs)
        : _rawState(initialState),
          _stableState(initialState),
          _debounceMs(debounceMs) {}

    bool update(bool rawState, uint32_t nowMs) {
        if (rawState != _rawState) {
            _rawState = rawState;
            _rawChangedAtMs = nowMs;
        }

        if (_stableState != _rawState &&
            static_cast<uint32_t>(nowMs - _rawChangedAtMs) >= _debounceMs) {
            _stableState = _rawState;
            return !_stableState;
        }
        return false;
    }

private:
    bool _rawState;
    bool _stableState;
    uint32_t _debounceMs;
    uint32_t _rawChangedAtMs = 0;
};