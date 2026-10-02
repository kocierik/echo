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

private:
    Preferences _preferences;
    bool _ready = false;
};