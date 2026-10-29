#pragma once

#include <cstddef>
#include <cstdint>

/**
 * Encrypts the speech the microSD keeps (SegmentLog): a stream cipher started on each
 * record's IV, the same call encrypting and decrypting (AES-256-CTR on the device,
 * sd_cipher.h; a stand-in in the native tests).
 */
class RecordCipher {
public:
    static constexpr size_t IV_SIZE = 16;

    virtual ~RecordCipher() {}
    /** A fresh IV for a new record. */
    virtual void newIv(uint8_t* iv) = 0;
    /** Starts the stream of a record. */
    virtual void start(const uint8_t* iv) = 0;
    /** Encrypts or decrypts the next `length` bytes of the stream, in place. */
    virtual void apply(uint8_t* data, size_t length) = 0;
};
