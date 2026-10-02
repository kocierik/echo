#pragma once

#include <functional>

class MuteState {
public:
    typedef std::function<bool(bool&)> LoadFunction;
    typedef std::function<bool(bool)> SaveFunction;

    MuteState(LoadFunction load, SaveFunction save)
        : _load(load), _save(save) {}

    bool begin() {
        _muted = false;
        bool loadedMuted = false;
        if (!_load || !_load(loadedMuted)) return false;
        _muted = loadedMuted;
        return true;
    }

    bool setMuted(bool muted) {
        if (_muted == muted) return true;
        _muted = muted;
        return _save && _save(_muted);
    }

    bool isMuted() const { return _muted; }

private:
    LoadFunction _load;
    SaveFunction _save;
    bool _muted = false;
};