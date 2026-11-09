#pragma once

#include <Preferences.h>

class DevicePreferences {
public:
    bool begin() {
        _ready = _preferences.begin("privacy", false);
        return _ready;
    }

    bool loadMuted(bool& muted) {
        muted = false;
        if (!_ready) return false;
        if (!_preferences.isKey("muted")) return true;
        if (_preferences.getType("muted") != PT_U8) return false;
        muted = _preferences.getBool("muted", false);
        return true;
    }

    bool saveMuted(bool muted) {
        if (!_ready) return false;
        return _preferences.putBool("muted", muted) == 1;
    }

    /** The microphone's gain set from the app, or `fallback` (MIC_GAIN) when never set. */
    uint8_t loadMicGain(uint8_t fallback) {
        if (!_ready || !_preferences.isKey("mic_gain")) return fallback;
        return _preferences.getUChar("mic_gain", fallback);
    }

    bool saveMicGain(uint8_t gain) {
        if (!_ready) return false;
        return _preferences.putUChar("mic_gain", gain) == 1;
    }

private:
    Preferences _preferences;
    bool _ready = false;
};