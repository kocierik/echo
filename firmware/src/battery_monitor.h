#pragma once

#include <Arduino.h>

#include "battery_level.h"
#include "config.h"

/** Reads the battery on BATTERY_ADC_PIN every BATTERY_SAMPLE_INTERVAL_MS. */
class BatteryMonitor {
public:
    void begin() {
        if (!BATTERY_DIVIDER_FITTED) {
            Serial.println("[Battery] no divider fitted (BATTERY_DIVIDER_FITTED 0): unknown");
            return;
        }
        analogReadResolution(12);
        analogSetPinAttenuation(BATTERY_ADC_PIN, ADC_11db);  // up to ~3.1 V at the pin
        sample();
    }

    /** True when the reported percentage changed. */
    bool update() {
        if (!BATTERY_DIVIDER_FITTED) return false;
        if (millis() - _lastSampleMs < BATTERY_SAMPLE_INTERVAL_MS) return false;
        return sample();
    }

    uint8_t percent() const { return _smoother.percent(); }

private:
    bool sample() {
        _lastSampleMs = millis();
        uint32_t sum = 0;
        for (int i = 0; i < BATTERY_SAMPLES; ++i) sum += analogReadMilliVolts(BATTERY_ADC_PIN);
        const uint32_t pinMv = sum / BATTERY_SAMPLES;
        const uint32_t batteryMv = BatteryLevel::batteryMillivolts(pinMv, BATTERY_DIVIDER_RATIO);
        const bool changed = _smoother.add(batteryMv);
        if (changed) {
            Serial.printf("[Battery] %u mV -> %u%%\n", static_cast<unsigned>(batteryMv),
                          _smoother.percent());
        }
        return changed;
    }

    BatteryLevel::Smoother _smoother;
    uint32_t _lastSampleMs = 0;
};
