#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "ble_protocol.h"

enum class BleTransportEventType : uint8_t {
    CONNECTED,
    MTU_CHANGED,
    CONTROL,
};

struct BleTransportEvent {
    BleTransportEventType type = BleTransportEventType::CONNECTED;
    uint16_t mtu = 0;
    uint16_t controlLength = 0;
    uint8_t controlData[EchoBleProtocol::MAX_CONTROL_FRAME_SIZE] = {};

    static BleTransportEvent connected() {
        return {};
    }

    static BleTransportEvent mtuChanged(uint16_t mtu) {
        BleTransportEvent event;
        event.type = BleTransportEventType::MTU_CHANGED;
        event.mtu = mtu;
        return event;
    }

    static BleTransportEvent control(const uint8_t* data, size_t length) {
        BleTransportEvent event;
        event.type = BleTransportEventType::CONTROL;
        event.controlLength = length > UINT16_MAX ? UINT16_MAX : static_cast<uint16_t>(length);
        if (data != nullptr) {
            const size_t copyLength = length < sizeof(event.controlData)
                ? length
                : sizeof(event.controlData);
            memcpy(event.controlData, data, copyLength);
        }
        return event;
    }
};

class BleTransportEventQueue {
public:
    static constexpr size_t CAPACITY = 16;

    bool push(const BleTransportEvent& event) {
        if (_count == CAPACITY) return false;
        _events[_tail] = event;
        _tail = (_tail + 1) % CAPACITY;
        ++_count;
        return true;
    }

    bool pop(BleTransportEvent& event) {
        if (_count == 0) return false;
        event = _events[_head];
        _head = (_head + 1) % CAPACITY;
        --_count;
        return true;
    }

    void clear() {
        _head = 0;
        _tail = 0;
        _count = 0;
    }

private:
    BleTransportEvent _events[CAPACITY] = {};
    size_t _head = 0;
    size_t _tail = 0;
    size_t _count = 0;
};

class BlePendingStatus {
public:
    void request(uint8_t errorCode = 0) {
        _pending = true;
        if (errorCode != 0) _errorCode = errorCode;
    }

    bool shouldNotify(bool connected, bool ready) const {
        return _pending && connected && ready;
    }

    void onNotifyResult(bool success) {
        if (!success) return;
        _pending = false;
        _errorCode = 0;
    }

    bool isPending() const { return _pending; }
    uint8_t errorCode() const { return _errorCode; }

private:
    uint8_t _errorCode = 0;
    bool _pending = false;
};