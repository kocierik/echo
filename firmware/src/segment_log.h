#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "ble_protocol.h"
#include "buffered_segment.h"
#include "record_cipher.h"

/**
 * The few file operations the SD queue needs (sd_storage.h on the device, memory in the
 * native tests). Paths are absolute; append and replace create the file.
 */
class LogStorage {
public:
    virtual ~LogStorage() {}
    virtual bool append(const char* path, const uint8_t* data, size_t length) = 0;
    /** The file's size, or -1 when it does not exist. */
    virtual long size(const char* path) = 0;
    virtual size_t read(const char* path, size_t offset, uint8_t* out, size_t length) = 0;
    virtual bool remove(const char* path) = 0;
    /** The file's whole content becomes `data`. */
    virtual bool replace(const char* path, const uint8_t* data, size_t length) = 0;
    virtual uint64_t freeBytes() = 0;
    virtual uint64_t totalBytes() = 0;
};

/**
 * Segments waiting for the phone, on the SD card: when the PSRAM queue is full its
 * oldest segments move here, and they go to the phone before the ones in PSRAM.
 *
 * Append-only log files (`<folder>/NNNNNNNN.log`, at most `fileLimit` bytes each) of
 * records `[BufferedSegment header | data]`; `<folder>/head` keeps the read position (file
 * number, offset), so a restart resumes where it was. A file is deleted once sent. A
 * record cut short by a power loss, or whose data fails its CRC, is skipped (and counted
 * as dropped), never sent. A full card drops the oldest file.
 *
 * With a cipher the data is encrypted on the card under its own IV, kept after the header
 * (`[header | IV | encrypted data]`); the header, which says nothing of what was said,
 * stays in clear. A record that does not decrypt to its CRC (another key) is skipped as a
 * corrupt one is. Without a cipher (0.6.0's `/echo/q`) the data is in clear.
 */
class SegmentLog {
public:
    static constexpr size_t HEADER_SIZE = BufferedSegmentCodec::HEADER_SIZE;

    SegmentLog(LogStorage& storage, uint32_t fileLimit, const char* folder = "/echo/q",
               RecordCipher* cipher = nullptr)
        : _storage(storage), _fileLimit(fileLimit), _folder(folder), _cipher(cipher) {}

    /**
     * Moves every segment of `from` into `to`, oldest first (0.6.0's records in clear into
     * the encrypted log), `buffer` holding one at a time; stops when `to` cannot take one.
     * Returns how many moved.
     */
    static uint32_t moveAll(SegmentLog& from, SegmentLog& to, uint8_t* buffer, size_t capacity) {
        uint32_t moved = 0;
        BufferedSegment header{};
        while (from.peek(header, buffer, capacity)) {
            if (!to.append(header, buffer)) break;
            from.dequeue();
            ++moved;
        }
        return moved;
    }

    /** Reads the position and finds the files; false when the card cannot be read. */
    bool begin() {
        uint8_t saved[8];
        char path[32];
        headPath(path);
        if (_storage.read(path, 0, saved, sizeof(saved)) == sizeof(saved)) {
            _head = EchoBleProtocol::readU32(saved);
            _headOffset = EchoBleProtocol::readU32(saved + 4);
        }
        _tail = _head;
        while (_storage.size(logPath(_tail + 1, path)) >= 0) ++_tail;
        _pending = 0;
        for (uint32_t file = _head; file <= _tail; ++file) {
            const long length = _storage.size(logPath(file, path));
            if (length > 0) _pending += static_cast<uint64_t>(length);
        }
        _pending = _pending > _headOffset ? _pending - _headOffset : 0;
        _total = _storage.totalBytes();
        _free = _storage.freeBytes();
        // A record cut short at the end of the last file: new ones start a fresh file,
        // so they are never written behind the broken one
        if (!endsCleanly(_tail, _tail == _head ? _headOffset : 0)) ++_tail;
        _ready = true;
        return true;
    }

    /** Adds a segment at the end; false when the card is full or fails. */
    bool append(const BufferedSegment& header, const uint8_t* data) {
        if (!_ready) return false;
        const size_t record = overhead() + header.dataLength;
        char path[32];
        const long tailSize = _storage.size(logPath(_tail, path));
        if (tailSize > 0 && static_cast<uint64_t>(tailSize) + record > _fileLimit) {
            ++_tail;
            logPath(_tail, path);
        }
        // Room on the card: the oldest file goes, never the one being written
        while (_storage.freeBytes() < record + HEADER_SIZE && _head < _tail) dropHeadFile();
        if (_storage.freeBytes() < record) return false;

        uint8_t encoded[HEADER_SIZE];
        BufferedSegmentCodec::encode(header, encoded);
        bool written = _storage.append(path, encoded, HEADER_SIZE);
        if (written && _cipher != nullptr) {
            written = appendSealed(path, data, header.dataLength);
        } else if (written && header.dataLength > 0) {
            written = _storage.append(path, data, header.dataLength);
        }
        _free = _storage.freeBytes();
        if (!written) return false;
        _pending += record;
        return true;
    }

    /**
     * The oldest segment that can be sent, its data copied to `out` (at most `capacity`
     * bytes); skips what cannot be sent. False when there is none.
     */
    bool peek(BufferedSegment& header, uint8_t* out, size_t capacity) {
        _peeked = 0;
        if (!_ready) return false;
        char path[32];
        while (true) {
            const long fileSize = _storage.size(logPath(_head, path));
            if (fileSize < 0 || _headOffset >= static_cast<uint64_t>(fileSize)) {
                if (_head >= _tail) return false;
                nextFile();
                continue;
            }
            uint8_t encoded[HEADER_SIZE];
            const bool whole =
                _storage.read(path, _headOffset, encoded, HEADER_SIZE) == HEADER_SIZE;
            const BufferedSegment found = BufferedSegmentCodec::decode(encoded);
            const size_t record = overhead() + found.dataLength;
            const uint64_t end = _headOffset + record;
            if (!whole || found.dataLength > capacity || end > static_cast<uint64_t>(fileSize)) {
                // Cut short (a power loss) or unreadable: the rest of this file is lost
                if (_head >= _tail) return false;
                ++_dropped;
                nextFile();
                continue;
            }
            if (found.dataLength > 0 &&
                _storage.read(path, _headOffset + overhead(), out, found.dataLength) !=
                    found.dataLength) {
                return false;
            }
            if (_cipher != nullptr) {
                uint8_t iv[RecordCipher::IV_SIZE];
                if (_storage.read(path, _headOffset + HEADER_SIZE, iv, sizeof(iv)) != sizeof(iv)) {
                    return false;
                }
                _cipher->start(iv);
                _cipher->apply(out, found.dataLength);
            }
            if (EchoBleProtocol::crc32(out, found.dataLength) != found.crc) {
                ++_dropped;
                advance(record);
                continue;
            }
            header = found;
            _peeked = record;
            return true;
        }
    }

    /** Removes the segment the last `peek` returned. */
    void dequeue() {
        if (_peeked == 0) return;
        advance(_peeked);
        _peeked = 0;
    }

    bool isEmpty() {
        if (!_ready) return true;
        char path[32];
        const long fileSize = _storage.size(logPath(_head, path));
        return _head >= _tail && (fileSize < 0 || _headOffset >= static_cast<uint64_t>(fileSize));
    }

    /** Bytes of segments still to send (headers included). */
    uint64_t pendingBytes() const { return _pending; }

    /** Segments lost on the card: cut short, corrupted, or dropped for room. */
    uint32_t droppedSegmentCount() const { return _dropped; }

    /** The card's size and room as last seen: kept up to date by the log's own writes and
     *  deletes, so reading them never touches the card. */
    uint64_t totalBytes() const { return _total; }
    uint64_t freeBytes() const { return _free; }

private:
    // Data is encrypted a piece at a time, in a copy
    static constexpr size_t SEAL_CHUNK = 1024;

    LogStorage& _storage;
    const uint32_t _fileLimit;
    const char* _folder;
    RecordCipher* _cipher;
    uint8_t _chunk[SEAL_CHUNK];
    uint64_t _total = 0;
    uint64_t _free = 0;
    uint32_t _head = 0;
    uint64_t _headOffset = 0;
    uint32_t _tail = 0;
    uint64_t _pending = 0;
    uint32_t _dropped = 0;
    size_t _peeked = 0;
    bool _ready = false;

    size_t overhead() const {
        return HEADER_SIZE + (_cipher != nullptr ? RecordCipher::IV_SIZE : 0);
    }

    const char* logPath(uint32_t file, char* out) const {
        snprintf(out, 32, "%s/%08lu.log", _folder, static_cast<unsigned long>(file));
        return out;
    }

    const char* headPath(char* out) const {
        snprintf(out, 32, "%s/head", _folder);
        return out;
    }

    /** A new IV, then the data encrypted under it. */
    bool appendSealed(const char* path, const uint8_t* data, size_t length) {
        uint8_t iv[RecordCipher::IV_SIZE];
        _cipher->newIv(iv);
        if (!_storage.append(path, iv, sizeof(iv))) return false;
        _cipher->start(iv);
        for (size_t done = 0; done < length;) {
            const size_t piece = length - done < SEAL_CHUNK ? length - done : SEAL_CHUNK;
            memcpy(_chunk, data + done, piece);
            _cipher->apply(_chunk, piece);
            if (!_storage.append(path, _chunk, piece)) return false;
            done += piece;
        }
        return true;
    }

    void saveHead() {
        uint8_t saved[8];
        EchoBleProtocol::writeU32(saved, _head);
        EchoBleProtocol::writeU32(saved + 4, static_cast<uint32_t>(_headOffset));
        char path[32];
        _storage.replace(headPath(path), saved, sizeof(saved));
    }

    /** Moves the read position past `bytes`, deleting a file once it is all sent. */
    void advance(uint64_t bytes) {
        _headOffset += bytes;
        _pending = _pending > bytes ? _pending - bytes : 0;
        char path[32];
        const long fileSize = _storage.size(logPath(_head, path));
        if (fileSize >= 0 && _headOffset >= static_cast<uint64_t>(fileSize)) {
            _storage.remove(path);
            if (_head < _tail) ++_head;
            _headOffset = 0;
        }
        saveHead();
        _free = _storage.freeBytes();
    }

    /** Leaves the head file (all of it: sent or unreadable) for the next one. */
    void nextFile() {
        char path[32];
        const long fileSize = _storage.size(logPath(_head, path));
        if (fileSize > 0 && static_cast<uint64_t>(fileSize) > _headOffset) {
            const uint64_t left = static_cast<uint64_t>(fileSize) - _headOffset;
            _pending = _pending > left ? _pending - left : 0;
        }
        _storage.remove(path);
        ++_head;
        _headOffset = 0;
        saveHead();
        _free = _storage.freeBytes();
    }

    /** Drops the oldest file to make room, counting the segments it held. */
    void dropHeadFile() {
        char path[32];
        logPath(_head, path);
        uint64_t offset = _headOffset;
        const long fileSize = _storage.size(path);
        uint8_t encoded[HEADER_SIZE];
        while (fileSize > 0 && offset + HEADER_SIZE <= static_cast<uint64_t>(fileSize) &&
               _storage.read(path, offset, encoded, HEADER_SIZE) == HEADER_SIZE) {
            ++_dropped;
            offset += overhead() + BufferedSegmentCodec::decode(encoded).dataLength;
        }
        nextFile();
    }

    /** Whether the records of `file` from `offset` end exactly at its end. */
    bool endsCleanly(uint32_t file, uint64_t offset) {
        char path[32];
        const long fileSize = _storage.size(logPath(file, path));
        if (fileSize <= 0) return true;
        uint8_t encoded[HEADER_SIZE];
        while (offset < static_cast<uint64_t>(fileSize)) {
            if (_storage.read(path, offset, encoded, HEADER_SIZE) != HEADER_SIZE) return false;
            offset += overhead() + BufferedSegmentCodec::decode(encoded).dataLength;
        }
        return offset == static_cast<uint64_t>(fileSize);
    }
};
