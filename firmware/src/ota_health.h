#pragma once

#include <cstdint>

/**
 * After an update the bootloader runs the new firmware "on trial": it is kept only once
 * the app talks to it again (connected, bonded, time set). If that does not happen in
 * `timeoutMs`, or the firmware crashes first, the previous one comes back.
 */
class OtaHealthCheck {
public:
    enum class Decision : uint8_t { NONE, KEEP, ROLL_BACK };

    explicit OtaHealthCheck(uint32_t timeoutMs) : _timeoutMs(timeoutMs) {}

    void begin(bool onTrial, uint32_t nowMs) {
        _onTrial = onTrial;
        _startedMs = nowMs;
    }

    Decision update(bool appTalking, uint32_t nowMs) {
        if (!_onTrial) return Decision::NONE;
        if (appTalking) {
            _onTrial = false;
            return Decision::KEEP;
        }
        if (nowMs - _startedMs >= _timeoutMs) {
            _onTrial = false;
            return Decision::ROLL_BACK;
        }
        return Decision::NONE;
    }

    bool onTrial() const { return _onTrial; }

private:
    uint32_t _timeoutMs;
    uint32_t _startedMs = 0;
    bool _onTrial = false;
};
