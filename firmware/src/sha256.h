#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

/** SHA-256 (FIPS 180-4): a firmware image is checked as it arrives, chunk by chunk. */
class Sha256 {
public:
    static constexpr size_t DIGEST_SIZE = 32;

    Sha256() { reset(); }

    void reset() {
        static const uint32_t initial[8] = {
            0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
            0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U,
        };
        memcpy(_state, initial, sizeof(_state));
        _length = 0;
        _blockUsed = 0;
    }

    void update(const uint8_t* data, size_t length) {
        _length += length;
        while (length > 0) {
            const size_t room = BLOCK_SIZE - _blockUsed;
            const size_t take = length < room ? length : room;
            memcpy(_block + _blockUsed, data, take);
            _blockUsed += take;
            data += take;
            length -= take;
            if (_blockUsed == BLOCK_SIZE) {
                compress(_block);
                _blockUsed = 0;
            }
        }
    }

    void finish(uint8_t digest[DIGEST_SIZE]) {
        const uint64_t bits = _length * 8;
        _block[_blockUsed++] = 0x80;
        if (_blockUsed > BLOCK_SIZE - 8) {
            memset(_block + _blockUsed, 0, BLOCK_SIZE - _blockUsed);
            compress(_block);
            _blockUsed = 0;
        }
        memset(_block + _blockUsed, 0, BLOCK_SIZE - 8 - _blockUsed);
        for (size_t index = 0; index < 8; ++index) {
            _block[BLOCK_SIZE - 1 - index] = static_cast<uint8_t>(bits >> (index * 8));
        }
        compress(_block);
        for (size_t word = 0; word < 8; ++word) {
            for (size_t byte = 0; byte < 4; ++byte) {
                digest[word * 4 + byte] = static_cast<uint8_t>(_state[word] >> (24 - byte * 8));
            }
        }
        reset();
    }

private:
    static constexpr size_t BLOCK_SIZE = 64;

    static uint32_t rotr(uint32_t value, uint32_t bits) {
        return (value >> bits) | (value << (32 - bits));
    }

    void compress(const uint8_t* block) {
        static const uint32_t k[64] = {
            0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U,
            0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
            0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U,
            0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
            0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
            0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
            0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
            0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
            0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU,
            0x5b9cca4fU, 0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
            0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
        };
        uint32_t w[64];
        for (size_t index = 0; index < 16; ++index) {
            w[index] = (static_cast<uint32_t>(block[index * 4]) << 24) |
                       (static_cast<uint32_t>(block[index * 4 + 1]) << 16) |
                       (static_cast<uint32_t>(block[index * 4 + 2]) << 8) |
                       static_cast<uint32_t>(block[index * 4 + 3]);
        }
        for (size_t index = 16; index < 64; ++index) {
            const uint32_t s0 = rotr(w[index - 15], 7) ^ rotr(w[index - 15], 18) ^ (w[index - 15] >> 3);
            const uint32_t s1 = rotr(w[index - 2], 17) ^ rotr(w[index - 2], 19) ^ (w[index - 2] >> 10);
            w[index] = w[index - 16] + s0 + w[index - 7] + s1;
        }
        uint32_t a = _state[0], b = _state[1], c = _state[2], d = _state[3];
        uint32_t e = _state[4], f = _state[5], g = _state[6], h = _state[7];
        for (size_t index = 0; index < 64; ++index) {
            const uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            const uint32_t choose = (e & f) ^ (~e & g);
            const uint32_t t1 = h + s1 + choose + k[index] + w[index];
            const uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
            const uint32_t t2 = s0 + majority;
            h = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = b;
            b = a;
            a = t1 + t2;
        }
        _state[0] += a;
        _state[1] += b;
        _state[2] += c;
        _state[3] += d;
        _state[4] += e;
        _state[5] += f;
        _state[6] += g;
        _state[7] += h;
    }

    uint32_t _state[8];
    uint64_t _length = 0;
    uint8_t _block[BLOCK_SIZE];
    size_t _blockUsed = 0;
};
