#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "ble_protocol.h"
#include "ota_signature.h"
#include "sha256.h"

/** Where a new image is written: the inactive app partition on the device, a fake in tests. */
class OtaFlash {
public:
    virtual ~OtaFlash() {}
    virtual uint32_t capacity() const = 0;
    virtual bool begin(uint32_t size) = 0;
    virtual bool write(const uint8_t* data, size_t length) = 0;
    /** Checks the image and makes it the one to boot next. */
    virtual bool finish() = 0;
    virtual void abort() = 0;
};

/**
 * A firmware image arriving over BLE: accepted only when the SHA-256 the app announces is
 * signed with the release key, written in order, hashed on the way, and made bootable only
 * when complete and identical to that SHA-256. Neither the server nor the phone holds the
 * key, so neither can install a firmware of its own.
 * The running firmware is never touched: a failed transfer leaves the device as it was.
 */
class OtaReceiver {
public:
    enum class State : uint8_t { IDLE, RECEIVING, DONE, FAILED };

    /** `publicKey`: the release key's public half, x||y (ota_public_key.h). */
    OtaReceiver(OtaFlash& flash, const uint8_t* publicKey)
        : _flash(flash), _publicKey(publicKey) {}

    /** OTA_ERROR_NONE when the image can be sent from offset 0; a new begin restarts. */
    uint8_t begin(uint32_t size, const uint8_t* sha256, const uint8_t* signature) {
        abort();
        if (size == 0 || size > _flash.capacity()) {
            return fail(EchoBleProtocol::OTA_ERROR_TOO_LARGE);
        }
        if (!otaSignatureValid(_publicKey, sha256, signature)) {
            return fail(EchoBleProtocol::OTA_ERROR_BAD_SIGNATURE);
        }
        if (!_flash.begin(size)) return fail(EchoBleProtocol::OTA_ERROR_FLASH);
        _size = size;
        memcpy(_expected, sha256, EchoBleProtocol::SHA256_SIZE);
        _state = State::RECEIVING;
        return EchoBleProtocol::OTA_ERROR_NONE;
    }

    /**
     * The chunk at `offset`. A chunk already written (an app retry) is ignored; a gap or
     * an overrun fails the transfer. The last chunk checks the image and finishes it.
     */
    uint8_t write(uint32_t offset, const uint8_t* data, size_t length) {
        if (_state != State::RECEIVING) return EchoBleProtocol::OTA_ERROR_NOT_STARTED;
        if (length == 0) return abortWith(EchoBleProtocol::OTA_ERROR_OUT_OF_ORDER);
        if (offset < _received && offset + length <= _received) {
            return EchoBleProtocol::OTA_ERROR_NONE;
        }
        if (offset != _received || length > _size - _received) {
            return abortWith(EchoBleProtocol::OTA_ERROR_OUT_OF_ORDER);
        }
        if (!_flash.write(data, length)) return abortWith(EchoBleProtocol::OTA_ERROR_FLASH);
        _hash.update(data, length);
        _received += length;
        if (_received < _size) return EchoBleProtocol::OTA_ERROR_NONE;

        uint8_t actual[EchoBleProtocol::SHA256_SIZE];
        _hash.finish(actual);
        if (memcmp(actual, _expected, sizeof(actual)) != 0) {
            return abortWith(EchoBleProtocol::OTA_ERROR_HASH_MISMATCH);
        }
        // finish() releases the flash either way: no abort after it
        if (!_flash.finish()) return fail(EchoBleProtocol::OTA_ERROR_INVALID_IMAGE);
        _state = State::DONE;
        return EchoBleProtocol::OTA_ERROR_NONE;
    }

    /** Back to IDLE, dropping a transfer in progress (disconnect, app abort, timeout). */
    void abort() {
        if (_state == State::RECEIVING) _flash.abort();
        _state = State::IDLE;
        _error = EchoBleProtocol::OTA_ERROR_NONE;
        _size = 0;
        _received = 0;
        _hash.reset();
    }

    State state() const { return _state; }
    uint8_t error() const { return _error; }
    uint32_t received() const { return _received; }
    uint32_t size() const { return _size; }

private:
    uint8_t fail(uint8_t error) {
        _state = State::FAILED;
        _error = error;
        return error;
    }

    uint8_t abortWith(uint8_t error) {
        _flash.abort();
        return fail(error);
    }

    OtaFlash& _flash;
    const uint8_t* _publicKey;
    State _state = State::IDLE;
    uint8_t _error = EchoBleProtocol::OTA_ERROR_NONE;
    uint32_t _size = 0;
    uint32_t _received = 0;
    uint8_t _expected[EchoBleProtocol::SHA256_SIZE] = {};
    Sha256 _hash;
};
