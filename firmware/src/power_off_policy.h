#pragma once

#include <cstdint>

/**
 * Turning Echo off without losing what it heard.
 *
 * PSRAM is lost in deep sleep; the card and the phone are not. Once asked, Echo stops
 * listening and moves PSRAM's segments to the card, or, without a card that takes them,
 * waits for the phone to collect them. Only an empty PSRAM lets it sleep. Until then the
 * turn-off can be cancelled. A firmware update refuses it: its restart needs Echo on.
 */
class PowerOffPolicy {
public:
    enum class State : uint8_t { ON, TURNING_OFF, OFF_NOW };
    enum class Request : uint8_t { ACCEPTED, REFUSED_UPDATING, ALREADY_TURNING_OFF };

    Request request(bool updating) {
        if (_state != State::ON) return Request::ALREADY_TURNING_OFF;
        if (updating) return Request::REFUSED_UPDATING;
        _state = State::TURNING_OFF;
        _cardRefused = false;
        return Request::ACCEPTED;
    }

    /** True when it turned back on. Too late once it is about to sleep. */
    bool cancel() {
        if (_state != State::TURNING_OFF) return false;
        _state = State::ON;
        return true;
    }

    bool shouldSpill(bool cardInUse) const {
        return _state == State::TURNING_OFF && cardInUse && !_cardRefused;
    }

    /** The card is full or failing: the rest waits for the phone. */
    void onCardRefused() { _cardRefused = true; }

    State update(uint16_t segmentsInMemory) {
        if (_state == State::TURNING_OFF && segmentsInMemory == 0) _state = State::OFF_NOW;
        return _state;
    }

    State state() const { return _state; }

private:
    State _state = State::ON;
    bool _cardRefused = false;
};
