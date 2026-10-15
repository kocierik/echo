#pragma once

#include <cstddef>
#include <cstdint>

/**
 * Battery charge from the LiPo voltage (pure logic, tested natively).
 *
 * The XIAO ESP32-S3 has no battery sense of its own: a 1:2 divider (two 200 kOhm
 * resistors between BAT+ and GND) feeds A0. A reading outside a plausible LiPo range
 * (no divider fitted, floating pin) is "unknown" (255), never a made-up percentage.
 */
namespace BatteryLevel {

constexpr uint8_t UNKNOWN = 255;
constexpr uint32_t MIN_PLAUSIBLE_MV = 2800;
constexpr uint32_t MAX_PLAUSIBLE_MV = 4500;

struct Point {
    uint32_t millivolts;
    uint8_t percent;
};

// Typical single-cell LiPo discharge curve under light load
constexpr Point CURVE[] = {
    {3300, 0}, {3500, 5}, {3600, 10}, {3700, 25}, {3750, 35}, {3800, 45},
    {3850, 55}, {3900, 65}, {3950, 72}, {4000, 80}, {4100, 90}, {4200, 100},
};
constexpr size_t CURVE_POINTS = sizeof(CURVE) / sizeof(CURVE[0]);

/** Battery millivolts from the divider's output (`ratio` = Vbat / Vpin). */
inline uint32_t batteryMillivolts(uint32_t pinMillivolts, float ratio) {
    return static_cast<uint32_t>(pinMillivolts * ratio + 0.5f);
}

inline uint8_t percentFromMillivolts(uint32_t millivolts) {
    if (millivolts < MIN_PLAUSIBLE_MV || millivolts > MAX_PLAUSIBLE_MV) return UNKNOWN;
    if (millivolts <= CURVE[0].millivolts) return 0;
    for (size_t i = 1; i < CURVE_POINTS; ++i) {
        if (millivolts <= CURVE[i].millivolts) {
            const Point& low = CURVE[i - 1];
            const Point& high = CURVE[i];
            const uint32_t span = high.millivolts - low.millivolts;
            const uint32_t offset = millivolts - low.millivolts;
            return static_cast<uint8_t>(
                low.percent + (offset * (high.percent - low.percent) + span / 2) / span);
        }
    }
    return 100;
}

/**
 * Smooths readings so the percentage does not jump with the load (the radio, the
 * camera): an exponential average, reported only when it moves by at least 1 %.
 */
class Smoother {
public:
    /** Adds a reading; true when the reported percentage changed. */
    bool add(uint32_t millivolts) {
        if (millivolts < MIN_PLAUSIBLE_MV || millivolts > MAX_PLAUSIBLE_MV) {
            _averageMv = 0;
            return setPercent(UNKNOWN);
        }
        _averageMv = _averageMv == 0 ? millivolts : (_averageMv * 3 + millivolts) / 4;
        return setPercent(percentFromMillivolts(_averageMv));
    }

    uint8_t percent() const { return _percent; }

private:
    bool setPercent(uint8_t percent) {
        if (percent == _percent) return false;
        _percent = percent;
        return true;
    }

    uint32_t _averageMv = 0;
    uint8_t _percent = UNKNOWN;
};

}  // namespace BatteryLevel
