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
        if (NimBLEDevice::setPower(20, NimBLETxPowerType::All)) {
            Serial.println("[BLE] TX power set to 20 dBm");
        } else {
            Serial.println("[BLE] failed to set BLE TX power");
        }

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
        if (processPendingDisconnect()) return;
        processNextEvent(buffer);
        if (takeEventOverflow()) restartActive();

        if (_pendingStatus.shouldNotify(_connected, _state.isReady())) {
            Serial.printf("[BLE] pending status notify connected=%d ready=%d\n",
                          _connected ? 1 : 0, _state.isReady() ? 1 : 0);
            _pendingStatus.onNotifyResult(notifyBufferStatus(buffer));
        }
        if (!_connected || !_timeAnchor.isValid()) {
            // suppressed frequent log to avoid spamming Serial
            return;
        }
        if (millis() < _notifyBackoffUntil) {
            Serial.printf("[BLE] notify backoff active ms=%u\n", static_cast<unsigned>(_notifyBackoffUntil - millis()));
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
            _crcOffset = 0;
            _crcAccumulator = EchoBleProtocol::CRC32_INITIAL_VALUE;
            _crcReady = false;
        }

        _state.update(millis());
        if (_state.phase() == BleTransferState::RESTARTING || !_state.canSend(millis())) return;

        if (_preambleStep == 0) {
            if (!_crcReady) {
                updateActiveCrc();
                return;
            }
            sendSegmentStart();
        } else if (_preambleStep == 1) {
            sendSegmentMetadata();
        } else {
            sendNextChunk();
        }
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

        void onConnect(NimBLEServer*, NimBLEConnInfo&) override {
            Serial.println("[BLE] onConnect");
            _owner.enqueueEvent(BleTransportEvent::connected());
        }

        void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) override {
            Serial.printf("[BLE] onDisconnect (reason=%d:%s)\n", reason, disconnectReasonName(reason));
            _owner.enqueueDisconnect(reason);
        }

        void onMTUChange(uint16_t mtu, NimBLEConnInfo&) override {
            Serial.printf("[BLE] onMTUChange mtu=%u\n", (unsigned)mtu);
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
            Serial.printf("[BLE] control write (%u bytes)\n", value.size());
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

    bool notifyAudio(const uint8_t* data, size_t length) {
        if (_audioCharacteristic == nullptr) {
            Serial.println("[BLE] notifyAudio: no audio characteristic");
            return false;
        }
        Serial.printf("[BLE] notifyAudio attempt len=%u connected=%d\n", (unsigned)length, _connected ? 1 : 0);
        const bool ok = _audioCharacteristic->notify(data, length);
        Serial.printf("[BLE] notifyAudio result=%d\n", ok ? 1 : 0);
        if (!ok) {
            _notifyBackoffUntil = millis() + 10;
            Serial.println("[BLE] notifyAudio failed, backing off");
        }
        return ok;
    }

    bool notifyBufferStatus(const PSRAMBuffer& buffer) {
        if (_controlCharacteristic == nullptr) return false;
        uint8_t frame[EchoBleProtocol::DEVICE_STATUS_SIZE] = {};
        EchoBleProtocol::encodeDeviceStatus(
            buffer.count(), static_cast<uint32_t>(buffer.bytesUsed()),
            _pendingStatus.errorCode(), frame, sizeof(frame));
        Serial.printf("[BLE] notifyBufferStatus count=%u bytes=%u error=%u\n",
                      buffer.count(), static_cast<unsigned>(buffer.bytesUsed()),
                      _pendingStatus.errorCode());
        const bool ok = _controlCharacteristic->notify(frame, sizeof(frame));
        Serial.printf("[BLE] notifyBufferStatus result=%d\n", ok ? 1 : 0);
        return ok;
    }

    void sendSegmentStart() {
        uint8_t frame[EchoBleProtocol::SEGMENT_START_SIZE] = {};
        const uint16_t chunks = static_cast<uint16_t>(
            (_segment.dataLength + _chunkPayloadSize - 1) / _chunkPayloadSize);
        const EchoBleProtocol::SegmentStart start = {
            _segment.segmentId,
            EchoBleProtocol::PROTOCOL_VERSION,
            _segment.dataLength,
            _segment.durationMs,
            chunks,
            _segmentCrc,
        };
        EchoBleProtocol::encodeSegmentStart(start, frame, sizeof(frame));
        if (notifyAudio(frame, sizeof(frame))) ++_preambleStep;
    }

    void sendSegmentMetadata() {
        uint64_t recordedAtSeconds = 0;
        if (!resolveUnixSeconds(_segment.capturedAtMs, recordedAtSeconds)) return;
        uint8_t frame[EchoBleProtocol::SEGMENT_METADATA_SIZE] = {};
        const EchoBleProtocol::SegmentMetadata metadata = {
            _segment.segmentId,
            recordedAtSeconds,
            _segment.silenceBeforeMs,
            _segment.avgEnergy,
        };
        EchoBleProtocol::encodeSegmentMetadata(metadata, frame, sizeof(frame));
        Serial.printf("[BLE] sendSegmentMetadata id=%u\n", _segment.segmentId);
        if (notifyAudio(frame, sizeof(frame))) ++_preambleStep;
    }

    void sendNextChunk() {
        const uint16_t sequence = _state.nextSequence();
        const size_t offset = static_cast<size_t>(sequence) * _chunkPayloadSize;
        if (offset >= _segment.dataLength) return;
        const size_t remaining = _segment.dataLength - offset;
        const size_t payloadLength = remaining < _chunkPayloadSize ? remaining : _chunkPayloadSize;
        uint8_t frame[EchoBleProtocol::NIMBLE_CHARACTERISTIC_MAX_LENGTH] = {};
        EchoBleProtocol::encodeSegmentDataHeader(
            _segment.segmentId, sequence, frame, sizeof(frame));
        memcpy(frame + EchoBleProtocol::SEGMENT_DATA_HEADER_SIZE,
               _segmentData + offset, payloadLength);
        if (notifyAudio(frame, EchoBleProtocol::SEGMENT_DATA_HEADER_SIZE + payloadLength)) {
            _state.onChunkSent(sequence, millis());
        }
    }

    bool resolveUnixSeconds(uint32_t capturedAtMs, uint64_t& unixSeconds) const {
        return _timeAnchor.resolveUnixSeconds(capturedAtMs, unixSeconds);
    }

    void updateActiveCrc() {
        const size_t remaining = _segment.dataLength - _crcOffset;
        const size_t length = remaining < CRC_BYTES_PER_UPDATE
            ? remaining
            : CRC_BYTES_PER_UPDATE;
        _crcAccumulator = EchoBleProtocol::crc32Update(
            _crcAccumulator, _segmentData + _crcOffset, length);
        _crcOffset += length;
        if (_crcOffset == _segment.dataLength) {
            _segmentCrc = EchoBleProtocol::crc32Finalize(_crcAccumulator);
            _crcReady = true;
        }
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
        _crcReady = false;
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

    void processNextEvent(PSRAMBuffer& buffer) {
        BleTransportEvent event;
        portENTER_CRITICAL(&_eventMux);
        const bool available = _events.pop(event);
        portEXIT_CRITICAL(&_eventMux);
        if (!available) return;

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
        _crcReady = false;
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
    size_t _crcOffset = 0;
    uint32_t _notifyBackoffUntil = 0;
    uint32_t _crcAccumulator = EchoBleProtocol::CRC32_INITIAL_VALUE;
    uint32_t _segmentCrc = 0;
    uint16_t _negotiatedMtu = 23;
    uint8_t _preambleStep = 0;
    bool _connected = false;
    bool _active = false;
    bool _crcReady = false;
    bool _disconnectPending = false;
    bool _eventOverflowPending = false;
    int _lastDisconnectReason = 0;
    portMUX_TYPE _eventMux = portMUX_INITIALIZER_UNLOCKED;
    EchoBleProtocol::TimeAnchor _timeAnchor;

    static constexpr size_t CRC_BYTES_PER_UPDATE = 512;
};