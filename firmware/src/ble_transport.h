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
            _pendingStatus.onNotifyResult(notifyBufferStatus(buffer));
        }
        if (!_connected || !_timeAnchor.isValid()) return;

        if (_state.phase() == BleTransferState::RESTARTING) {
            _preambleStep = 0;
            _state.restartComplete(millis());
        }

        if (!_active) {
            if (!buffer.peek(_segment, &_segmentData)) return;
            _chunkPayloadSize = payloadSizeForMtu();
            if (_chunkPayloadSize == 0) return;
            const size_t chunks = (_segment.dataLength + _chunkPayloadSize - 1) / _chunkPayloadSize;
            if (chunks == 0 || chunks > UINT16_MAX) return;
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
        _pendingStatus.request();
    }

    void reportBufferFull() {
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
            Serial.printf("[BLE] onDisconnect (reason=%d)\n", reason);
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
        return EchoBleProtocol::segmentDataPayloadSizeForMtu(mtu);
    }

    bool notifyAudio(const uint8_t* data, size_t length) {
        if (_audioCharacteristic == nullptr) {
            Serial.println("[BLE] notifyAudio: no audio characteristic");
            return false;
        }
        Serial.printf("[BLE] notifyAudio attempt len=%u connected=%d\n", (unsigned)length, _connected ? 1 : 0);
        const bool ok = _audioCharacteristic->notify(data, length);
        Serial.printf("[BLE] notifyAudio result=%d\n", ok ? 1 : 0);
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

    bool notifyBufferStatus(const PSRAMBuffer& buffer) {
        if (_controlCharacteristic == nullptr) return false;
        uint8_t frame[EchoBleProtocol::DEVICE_STATUS_SIZE] = {};
        EchoBleProtocol::encodeDeviceStatus(
            buffer.count(), static_cast<uint32_t>(buffer.bytesUsed()),
            _pendingStatus.errorCode(), frame, sizeof(frame));
        return _controlCharacteristic->notify(frame, sizeof(frame));
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

        Serial.printf("[BLE] processing pending disconnect (reason=%d)\n", _lastDisconnectReason);
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
                _connected = true;
                _negotiatedMtu = 23;
                _pendingStatus.request();
                break;
            case BleTransportEventType::MTU_CHANGED:
                if (_connected) _negotiatedMtu = event.mtu;
                break;
            case BleTransportEventType::CONTROL:
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
            restartActive();
            return;
        }

        switch (frame.type) {
            case EchoBleProtocol::FRAME_SET_TIME:
                _timeAnchor.set(frame.unixMilliseconds, millis(), frame.timezoneOffsetMinutes);
                break;
            case EchoBleProtocol::FRAME_READY:
                _state.onReady();
                break;
            case EchoBleProtocol::FRAME_ACK_WINDOW:
                if (!_state.onAckWindow(frame.segmentId, frame.sequence, millis())) restartActive();
                break;
            case EchoBleProtocol::FRAME_RESTART_SEGMENT:
                if (!_state.onRestartSegment(frame.segmentId)) restartActive();
                break;
            case EchoBleProtocol::FRAME_UPLOAD_OK:
                acceptUpload(frame.segmentId, buffer);
                break;
        }
    }

    void acceptUpload(uint32_t segmentId, PSRAMBuffer& buffer) {
        if (!_active) return;
        if (!_state.canAcceptUploadOk(segmentId)) {
            restartActive();
            return;
        }
        BufferedSegment oldest = {};
        const uint8_t* data = nullptr;
        if (!buffer.peek(oldest, &data) || oldest.segmentId != segmentId) {
            restartActive();
            return;
        }

        buffer.dequeue();
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