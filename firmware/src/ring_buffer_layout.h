#pragma once

#include <cstddef>
#include <cstdint>

class RingBufferLayout {
public:
    explicit RingBufferLayout(size_t capacity)
        : _capacity(capacity), _wrapBoundary(capacity) {}

    bool reserve(size_t size, size_t& offset) {
        if (size == 0 || size > _capacity - _bytesUsed) return false;

        if (_count == 0) reset();

        if (!_wrapped) {
            if (size <= _capacity - _tail) {
                offset = _tail;
                _tail += size;
            } else {
                if (size > _head) return false;
                _wrapBoundary = _tail;
                _wrapped = true;
                offset = 0;
                _tail = size;
            }
        } else {
            if (_tail > _head || size > _head - _tail) return false;
            offset = _tail;
            _tail += size;
        }

        ++_count;
        _bytesUsed += size;
        return true;
    }

    size_t frontOffset() const { return _head; }

    void pop(size_t size) {
        if (_count == 0 || size > _bytesUsed) return;
        _head += size;
        _bytesUsed -= size;
        --_count;

        if (_count == 0) {
            reset();
        } else if (_wrapped && _head >= _wrapBoundary) {
            _head = 0;
            _wrapped = false;
            _wrapBoundary = _capacity;
        }
    }

    uint16_t count() const { return _count; }
    size_t bytesUsed() const { return _bytesUsed; }

private:
    void reset() {
        _head = 0;
        _tail = 0;
        _wrapBoundary = _capacity;
        _bytesUsed = 0;
        _count = 0;
        _wrapped = false;
    }

    size_t _capacity;
    size_t _head = 0;
    size_t _tail = 0;
    size_t _wrapBoundary;
    size_t _bytesUsed = 0;
    uint16_t _count = 0;
    bool _wrapped = false;
};