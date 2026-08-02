#pragma once

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <freertos/FreeRTOS.h>

#include "ble_protocol.h"
#include "ble_transport_events.h"
#include "ble_transfer_state.h"
#include "config.h"
#include "psram_buffer.h"

class BleTransport {
public:
    BleTransport()
        : _serverCallbacks(*this), _controlCallbacks(*this) {}

    bool begin() {
        Serial.println("[BLE] init");
        NimBLEDevice::init(BLE_DEVICE_NAME);
        Serial.println("[BLE] NimBLEDevice initialized");
        NimBLEDevice::setMTU(BLE_PREFERRED_MTU);
        // Max TX power (+20dBm) can brown out the XIAO's regulator during
        // notification bursts, corrupting radio timing into supervision timeouts.
        // Use the stack's default power instead of forcing the highest level.

        _server = NimBLEDevice::createServer();
        if (_server == nullptr) return false;
        _server->setCallbacks(&_serverCallbacks);

        NimBLEService* service = _server->createService(BLE_SERVICE_UUID);
        if (service == nullptr) return false;
        _audioCharacteristic = service->createCharacteristic(
            BLE_AUDIO_CHARACTERISTIC_UUID, NIMBLE_PROPERTY::NOTIFY,
            EchoBleProtocol::NIMBLE_CHARACTERISTIC_MAX_LENGTH);
        _controlCharacteristic = service->createCharacteristic(
            BLE_CONTROL_CHARACTERISTIC_UUID,
            NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY,
            EchoBleProtocol::NIMBLE_CHARACTERISTIC_MAX_LENGTH);
        if (_audioCharacteristic == nullptr || _controlCharacteristic == nullptr) return false;

        _controlCharacteristic->setCallbacks(&_controlCallbacks);
        service->start();

        NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
        advertising->addServiceUUID(BLE_SERVICE_UUID);
        advertising->enableScanResponse(true);
        // Explicitly set the advertised device name to improve discovery
        advertising->setName(BLE_DEVICE_NAME);
        advertising->setAppearance(0x0000);
        advertising->start();
        Serial.println("[BLE] Advertising started");
        return true;
    }

    void update(PSRAMBuffer& buffer) {
        const uint32_t burstStartedUs = micros();
        const uint32_t deadlineUs = burstStartedUs + BleBurstDecision::BURST_BUDGET_US;
        uint8_t notificationsSent = 0;
        if (processPendingDisconnect()) return;
        while (beforeBurstDeadline(deadlineUs) && processNextEvent(buffer)) {}
        if (takeEventOverflow()) restartActive();
        if (!beforeBurstDeadline(deadlineUs)) return;

        if (_pendingStatus.shouldNotify(_connected, _state.isReady())) {
            const bool notified = notifyBufferStatus(buffer, deadlineUs);
            _pendingStatus.onNotifyResult(notified);
            if (notified) ++notificationsSent;
            if (!notified || !beforeBurstDeadline(deadlineUs)) return;
        }
        if (!_connected || !_timeAnchor.isValid() || !_state.isReady()) {
            return;
        }
        if (millis() < _notifyBackoffUntil) {
            return;
        }

        if (_state.phase() == BleTransferState::RESTARTING) {
            _preambleStep = 0;
            _state.restartComplete(millis());
        }

        if (!_active) {
            if (!buffer.peek(_segment, &_segmentData)) return;
            Serial.printf("[BLE] next segment id=%u len=%u\n", _segment.segmentId,
                          static_cast<unsigned>(_segment.dataLength));
            _chunkPayloadSize = payloadSizeForMtu();
            if (_chunkPayloadSize == 0) return;
            const size_t chunks = (_segment.dataLength + _chunkPayloadSize - 1) / _chunkPayloadSize;
            if (chunks == 0 || chunks > UINT16_MAX) return;
            Serial.printf("[BLE] beginSegment id=%u chunks=%u payloadSize=%u mtu=%u\n",
                          _segment.segmentId, static_cast<unsigned>(chunks),
                          static_cast<unsigned>(_chunkPayloadSize), _negotiatedMtu);
            _state.beginSegment(_segment.segmentId, static_cast<uint16_t>(chunks), millis());
            _active = true;
            _preambleStep = 0;
        }

        _state.update(millis());
        if (_state.phase() == BleTransferState::RESTARTING || !_state.canSend(millis())) return;

        bool notified = true;
        do {
            if (_preambleStep == 0) {
                notified = sendSegmentStart(deadlineUs);
            } else if (_preambleStep == 1) {
                notified = sendSegmentMetadata(deadlineUs);
            } else {
                notified = sendNextChunk(deadlineUs);
            }
            if (notified) ++notificationsSent;
        } while (BleBurstDecision::shouldContinue(
            notified,
            _state.canSend(millis()),
            static_cast<uint32_t>(micros() - burstStartedUs),
            notificationsSent));
    }

    bool isConnected() const { return _connected; }

    void requestBufferStatus() {
        Serial.println("[BLE] requestBufferStatus");
        _pendingStatus.request();
    }

    void reportBufferFull() {
        Serial.println("[BLE] reportBufferFull");
        _pendingStatus.request(BLE_STATUS_ERROR_BUFFER_FULL);
    }

private:
    class ServerCallbacks : public NimBLEServerCallbacks {
    public:
        explicit ServerCallbacks(BleTransport& owner) : _owner(owner) {}

        // Callbacks run on the NimBLE host task; Serial I/O here can block on a
        // full USB CDC buffer long enough to miss the supervision timeout window.
        // Log the same info later from update(), which runs on the Arduino task.
        void onConnect(NimBLEServer*, NimBLEConnInfo&) override {
            _owner.enqueueEvent(BleTransportEvent::connected());
        }

        void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) override {
            _owner.enqueueDisconnect(reason);
        }

        void onMTUChange(uint16_t mtu, NimBLEConnInfo&) override {
            _owner.enqueueEvent(BleTransportEvent::mtuChanged(mtu));
        }

    private:
        BleTransport& _owner;
    };

    class ControlCallbacks : public NimBLECharacteristicCallbacks {
    public:
        explicit ControlCallbacks(BleTransport& owner) : _owner(owner) {}

        void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo&) override {
            const NimBLEAttValue& value = characteristic->getValue();
            _owner.enqueueEvent(BleTransportEvent::control(value.data(), value.size()));
        }

    private:
        BleTransport& _owner;
    };

    size_t payloadSizeForMtu() const {
        const uint16_t mtu = _negotiatedMtu >= 23 ? _negotiatedMtu : 23;
        const uint16_t effectiveMtu = mtu > 247 ? 247 : mtu;
        return EchoBleProtocol::segmentDataPayloadSizeForMtu(effectiveMtu);
    }

    bool notifyAudio(const uint8_t* data, size_t length, uint32_t deadlineUs) {
        if (_audioCharacteristic == nullptr) {
            Serial.println("[BLE] notifyAudio: no audio characteristic");
            return false;
        }
        if (!beforeBurstDeadline(deadlineUs)) return false;
        const bool ok = _audioCharacteristic->notify(data, length);
        if (!ok) {
            _notifyBackoffUntil = millis() + 10;
            const uint32_t nowMs = millis();
            if (_lastNotifyFailureLogMs == 0 || nowMs - _lastNotifyFailureLogMs >= 1000) {
                _lastNotifyFailureLogMs = nowMs;
                Serial.println("[BLE] notification queue full; transfer paused");
            }
        }
        return ok;
    }

    bool notifyBufferStatus(const PSRAMBuffer& buffer, uint32_t deadlineUs) {
        if (_controlCharacteristic == nullptr) return false;
        uint8_t frame[EchoBleProtocol::DEVICE_STATUS_SIZE] = {};
        EchoBleProtocol::encodeDeviceStatus(
            buffer.count(), static_cast<uint32_t>(buffer.bytesUsed()),
            _pendingStatus.errorCode(), frame, sizeof(frame));
        if (!beforeBurstDeadline(deadlineUs)) return false;
        return _controlCharacteristic->notify(frame, sizeof(frame));
    }

    bool sendSegmentStart(uint32_t deadlineUs) {
        uint8_t frame[EchoBleProtocol::SEGMENT_START_SIZE] = {};
        const uint16_t chunks = static_cast<uint16_t>(
            (_segment.dataLength + _chunkPayloadSize - 1) / _chunkPayloadSize);
        const EchoBleProtocol::SegmentStart start = {
            _segment.segmentId,
            EchoBleProtocol::PROTOCOL_VERSION,
            _segment.dataLength,
            _segment.durationMs,
            chunks,
            _segment.crc,
        };
        EchoBleProtocol::encodeSegmentStart(start, frame, sizeof(frame));
        if (!notifyAudio(frame, sizeof(frame), deadlineUs)) return false;
        ++_preambleStep;
        Serial.printf("[BLE] transfer started segment=%u chunks=%u\n",
                      _segment.segmentId, chunks);
        return true;
    }

    bool sendSegmentMetadata(uint32_t deadlineUs) {
        uint64_t recordedAtSeconds = 0;
        if (!resolveUnixSeconds(_segment.capturedAtMs, recordedAtSeconds)) return false;
        uint8_t frame[EchoBleProtocol::SEGMENT_METADATA_SIZE] = {};
        const EchoBleProtocol::SegmentMetadata metadata = {
            _segment.segmentId,
            recordedAtSeconds,
            _segment.silenceBeforeMs,
            _segment.avgEnergy,
        };
        EchoBleProtocol::encodeSegmentMetadata(metadata, frame, sizeof(frame));
        if (!notifyAudio(frame, sizeof(frame), deadlineUs)) return false;
        ++_preambleStep;
        return true;
    }

    bool sendNextChunk(uint32_t deadlineUs) {
        const uint16_t sequence = _state.nextSequence();
        const size_t offset = static_cast<size_t>(sequence) * _chunkPayloadSize;
        if (offset >= _segment.dataLength) return false;
        const size_t remaining = _segment.dataLength - offset;
        const size_t payloadLength = remaining < _chunkPayloadSize ? remaining : _chunkPayloadSize;
        uint8_t frame[EchoBleProtocol::NIMBLE_CHARACTERISTIC_MAX_LENGTH] = {};
        EchoBleProtocol::encodeSegmentDataHeader(
            _segment.segmentId, sequence, frame, sizeof(frame));
        memcpy(frame + EchoBleProtocol::SEGMENT_DATA_HEADER_SIZE,
               _segmentData + offset, payloadLength);
        if (!notifyAudio(
            frame, EchoBleProtocol::SEGMENT_DATA_HEADER_SIZE + payloadLength,
            deadlineUs)) {
            return false;
        }
        _state.onChunkSent(sequence, millis());
        return true;
    }

    bool resolveUnixSeconds(uint32_t capturedAtMs, uint64_t& unixSeconds) const {
        return _timeAnchor.resolveUnixSeconds(capturedAtMs, unixSeconds);
    }

    static bool beforeBurstDeadline(uint32_t deadlineUs) {
        return BleBurstDecision::beforeDeadline(micros(), deadlineUs);
    }

    void enqueueEvent(const BleTransportEvent& event) {
        portENTER_CRITICAL(&_eventMux);
        if (!_events.push(event)) _eventOverflowPending = true;
        portEXIT_CRITICAL(&_eventMux);
    }

    void enqueueDisconnect(int reason) {
        portENTER_CRITICAL(&_eventMux);
        _disconnectPending = true;
        _lastDisconnectReason = reason;
        portEXIT_CRITICAL(&_eventMux);
    }

    static const char* disconnectReasonName(int reason) {
        switch (reason) {
            case 520: return "BLE_ERR_CONN_SPVN_TMO";
            case 33: return "BLE_ERR_REM_USER_CONN_TERM";
            case 19: return "BLE_ERR_CONN_TERM_LOCAL";
            case 22: return "BLE_ERR_L2C_CONN_FAIL";
            default: return "UNKNOWN_REASON";
        }
    }

    bool processPendingDisconnect() {
        portENTER_CRITICAL(&_eventMux);
        const bool pending = _disconnectPending;
        if (pending) {
            _disconnectPending = false;
            _eventOverflowPending = false;
            _events.clear();
        }
        portEXIT_CRITICAL(&_eventMux);
        if (!pending) return false;

        Serial.printf("[BLE] processing pending disconnect (reason=%d:%s)\n", _lastDisconnectReason,
                      disconnectReasonName(_lastDisconnectReason));
        _connected = false;
        _active = false;
        _segmentData = nullptr;
        _state.onDisconnected();
        NimBLEDevice::startAdvertising();
        return true;
    }

    bool takeEventOverflow() {
        portENTER_CRITICAL(&_eventMux);
        const bool pending = _eventOverflowPending;
        _eventOverflowPending = false;
        portEXIT_CRITICAL(&_eventMux);
        return pending;
    }

    bool processNextEvent(PSRAMBuffer& buffer) {
        BleTransportEvent event;
        portENTER_CRITICAL(&_eventMux);
        const bool available = _events.pop(event);
        portEXIT_CRITICAL(&_eventMux);
        if (!available) return false;

        switch (event.type) {
            case BleTransportEventType::CONNECTED:
                Serial.println("[BLE] event CONNECTED");
                _connected = true;
                _negotiatedMtu = 23;
                _pendingStatus.request();
                break;
            case BleTransportEventType::MTU_CHANGED:
                Serial.printf("[BLE] event MTU_CHANGED mtu=%u\n", event.mtu);
                if (_connected) _negotiatedMtu = event.mtu;
                break;
            case BleTransportEventType::CONTROL:
                Serial.printf("[BLE] event CONTROL len=%u\n", event.controlLength);
                if (_connected) handleControl(
                    event.controlData, event.controlLength, buffer);
                break;
        }
            return true;
    }

    void restartActive() {
        if (_active) _state.onRestartSegment(_segment.segmentId);
    }

    void handleControl(const uint8_t* data, size_t length, PSRAMBuffer& buffer) {
        EchoBleProtocol::ControlFrame frame = {};
        if (!EchoBleProtocol::decodeControlFrame(data, length, frame)) {
            Serial.printf("[BLE] handleControl decode failed len=%u\n", (unsigned)length);
            restartActive();
            return;
        }

        switch (frame.type) {
            case EchoBleProtocol::FRAME_SET_TIME:
                Serial.printf("[BLE] control FRAME_SET_TIME unixMs=%llu tz=%d\n",
                              static_cast<unsigned long long>(frame.unixMilliseconds),
                              frame.timezoneOffsetMinutes);
                _timeAnchor.set(frame.unixMilliseconds, millis(), frame.timezoneOffsetMinutes);
                break;
            case EchoBleProtocol::FRAME_READY:
                Serial.println("[BLE] control FRAME_READY");
                _state.onReady();
                break;
            case EchoBleProtocol::FRAME_ACK_WINDOW:
                Serial.printf("[BLE] control FRAME_ACK_WINDOW seg=%u highest=%u\n",
                              frame.segmentId, frame.sequence);
                if (!_state.onAckWindow(frame.segmentId, frame.sequence, millis())) restartActive();
                else if (_state.phase() == BleTransferState::WAITING_UPLOAD) {
                    Serial.printf("[BLE] transfer complete segment=%u\n", frame.segmentId);
                }
                break;
            case EchoBleProtocol::FRAME_RESTART_SEGMENT:
                Serial.printf("[BLE] control FRAME_RESTART_SEGMENT seg=%u\n", frame.segmentId);
                if (!_state.onRestartSegment(frame.segmentId)) restartActive();
                break;
            case EchoBleProtocol::FRAME_UPLOAD_OK:
                Serial.printf("[BLE] control FRAME_UPLOAD_OK seg=%u\n", frame.segmentId);
                acceptUpload(frame.segmentId, buffer);
                break;
            default:
                Serial.printf("[BLE] control unknown type=%u\n", frame.type);
                break;
        }
    }

    void acceptUpload(uint32_t segmentId, PSRAMBuffer& buffer) {
        if (!_active) return;
        if (!_state.canAcceptUploadOk(segmentId)) {
            Serial.printf("[BLE] acceptUpload rejected segment=%u state=%d\n", segmentId, _state.phase());
            restartActive();
            return;
        }
        BufferedSegment oldest = {};
        const uint8_t* data = nullptr;
        if (!buffer.peek(oldest, &data) || oldest.segmentId != segmentId) {
            Serial.printf("[BLE] acceptUpload missing segment=%u\n", segmentId);
            restartActive();
            return;
        }

        buffer.dequeue();
        Serial.printf("[BLE] upload accepted segment=%u\n", segmentId);
        _state.uploadAccepted();
        _active = false;
        _segmentData = nullptr;
        _pendingStatus.request();
    }

    NimBLEServer* _server = nullptr;
    NimBLECharacteristic* _audioCharacteristic = nullptr;
    NimBLECharacteristic* _controlCharacteristic = nullptr;
    ServerCallbacks _serverCallbacks;
    ControlCallbacks _controlCallbacks;
    BleTransferState _state;
    BleTransportEventQueue _events;
    BlePendingStatus _pendingStatus;
    BufferedSegment _segment = {};
    const uint8_t* _segmentData = nullptr;
    size_t _chunkPayloadSize = 0;
    uint32_t _notifyBackoffUntil = 0;
    uint32_t _lastNotifyFailureLogMs = 0;
    uint16_t _negotiatedMtu = 23;
    uint8_t _preambleStep = 0;
    bool _connected = false;
    bool _active = false;
    bool _disconnectPending = false;
    bool _eventOverflowPending = false;
    int _lastDisconnectReason = 0;
    portMUX_TYPE _eventMux = portMUX_INITIALIZER_UNLOCKED;
    EchoBleProtocol::TimeAnchor _timeAnchor;
};