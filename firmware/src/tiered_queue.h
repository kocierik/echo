#pragma once

#include <cstddef>
#include <cstdint>

#include "buffered_segment.h"
#include "segment_log.h"

/**
 * The segments waiting for the phone: the PSRAM queue (`Hot`, PSRAMBuffer on the device)
 * and, with a microSD card, its overflow on the card (SegmentLog).
 *
 * When PSRAM has no room for a new segment, its oldest segments move to the card instead
 * of being dropped; they are older than everything in PSRAM, so the transport reads the
 * card first, then PSRAM: the phone gets the segments oldest first. Without a card, or
 * when the card fails, `store` refuses as PSRAM alone does and the caller drops the
 * oldest, as before.
 */
/** The microSD as the phone sees it (DEVICE_STATUS). */
struct CardStatus {
    bool inUse;
    uint32_t totalMb;
    uint32_t freeMb;
    uint32_t pendingKb;
};

template <typename Hot>
class TieredQueue {
public:
    /** Called with a segment's id before it moves to the card (the transport may be
     *  sending it from PSRAM: it must stop). */
    typedef void (*MoveCallback)(uint32_t segmentId);

    /** This boot's capture millis as unix seconds; false while the time is unknown. */
    typedef bool (*UnixClock)(uint32_t capturedAtMs, uint32_t& unixSeconds);

    explicit TieredQueue(Hot& hot) : _hot(hot) {}

    /** Uses the card; `staging` holds one segment read from it (as large as a segment). */
    void attachCard(SegmentLog* card, uint8_t* staging, size_t stagingSize, MoveCallback onMove) {
        _card = card;
        _staging = staging;
        _stagingSize = stagingSize;
        _onMove = onMove;
    }

    /** Segments reaching the card carry unix time when this clock knows it: the card keeps
     *  them through deep sleep, after which this boot's millis mean nothing. */
    void setClock(UnixClock clock) { _clock = clock; }

    bool hasCard() const { return _card != nullptr; }

    bool store(uint32_t segmentId, const uint8_t* data, size_t length, uint32_t durationMs,
               uint32_t silenceBeforeMs, uint32_t capturedAtMs, uint16_t avgEnergy,
               uint32_t crc) {
        if (_hot.store(segmentId, data, length, durationMs, silenceBeforeMs, capturedAtMs,
                       avgEnergy, crc)) {
            return true;
        }
        if (_card == nullptr) return false;
        // The oldest move to the card until the newest fits
        BufferedSegment oldest = {};
        const uint8_t* oldestData = nullptr;
        while (_hot.peek(oldest, &oldestData)) {
            if (_onMove != nullptr) _onMove(oldest.segmentId);
            // Without the time it stays boot-relative: the phone usually connects later in
            // this boot and resolves it
            stampTime(oldest);
            if (!_card->append(oldest, oldestData)) return false;  // full or failing
            _hot.dequeue();
            if (_hot.store(segmentId, data, length, durationMs, silenceBeforeMs,
                           capturedAtMs, avgEnergy, crc)) {
                return true;
            }
        }
        return false;
    }

    enum class Spill : uint8_t { MOVED, EMPTY, REFUSED };

    /** Turning off: PSRAM's oldest segment to the card, which keeps it through deep sleep.
     *  EMPTY once PSRAM holds nothing; REFUSED without a card, or when it is full or
     *  failing (the segment stays in PSRAM, for the phone). */
    Spill spillOldestToCard() {
        BufferedSegment oldest = {};
        const uint8_t* oldestData = nullptr;
        if (!_hot.peek(oldest, &oldestData)) return Spill::EMPTY;
        if (_card == nullptr) return Spill::REFUSED;
        if (_onMove != nullptr) _onMove(oldest.segmentId);
        // Echo is about to sleep: without the time now, it is unknown (0) after the wake
        if (!stampTime(oldest)) {
            oldest.unixTime = true;
            oldest.capturedAtMs = 0;
        }
        if (!_card->append(oldest, oldestData)) return Spill::REFUSED;
        _hot.dequeue();
        return Spill::MOVED;
    }

    /** Segments only in PSRAM: lost if Echo sleeps now. */
    uint16_t memoryCount() const { return _hot.count(); }

    /** The oldest segment: the card's first, then PSRAM's. `data` stays valid until the
     *  next peek or dequeue. */
    bool peek(BufferedSegment& header, const uint8_t** data) {
        if (_card != nullptr && _card->pendingBytes() > 0 &&
            _card->peek(header, _staging, _stagingSize)) {
            *data = _staging;
            _fromCard = true;
            return true;
        }
        _fromCard = false;
        return _hot.peek(header, data);
    }

    /** Removes the segment the last peek returned. */
    void dequeue() {
        if (_fromCard) {
            _card->dequeue();
            _fromCard = false;
        } else {
            _hot.dequeue();
        }
    }

    /** Drops PSRAM's oldest (when even the card cannot take it); its id, or 0. */
    uint32_t dropOldest() { return _hot.dropOldest(); }

    bool hasSpace(size_t length) const { return _hot.hasSpace(length); }

    /** Segments waiting; those on the card are estimated from their bytes. */
    uint16_t count() const {
        uint32_t total = _hot.count();
        if (_card != nullptr && _card->pendingBytes() > 0) {
            total += static_cast<uint32_t>(_card->pendingBytes() / ESTIMATED_SEGMENT_BYTES) + 1;
        }
        return total > UINT16_MAX ? UINT16_MAX : static_cast<uint16_t>(total);
    }

    /** Bytes waiting, PSRAM and card (capped for the 32-bit status field). */
    size_t bytesUsed() const {
        uint64_t total = _hot.bytesUsed();
        if (_card != nullptr) total += _card->pendingBytes();
        return total > UINT32_MAX ? UINT32_MAX : static_cast<size_t>(total);
    }

    /** Whether the card is in use, its size and room, and the speech waiting on it; from
     *  what the log keeps, never a read of the card. */
    CardStatus cardStatus() const {
        if (_card == nullptr) return CardStatus{false, 0, 0, 0};
        const uint64_t mb = 1024ULL * 1024;
        return CardStatus{
            true,
            capped(_card->totalBytes() / mb),
            capped(_card->freeBytes() / mb),
            capped((_card->pendingBytes() + 1023) / 1024),
        };
    }

    uint32_t droppedSegmentCount() const {
        return _hot.droppedSegmentCount() + (_card != nullptr ? _card->droppedSegmentCount() : 0);
    }

private:
    /** To unix time when the clock knows it; true once the header carries unix time. */
    bool stampTime(BufferedSegment& header) const {
        if (header.unixTime) return true;
        uint32_t unixSeconds = 0;
        if (_clock == nullptr || !_clock(header.capturedAtMs, unixSeconds)) return false;
        header.unixTime = true;
        header.capturedAtMs = unixSeconds;
        return true;
    }

    static uint32_t capped(uint64_t value) {
        return value > UINT32_MAX ? UINT32_MAX : static_cast<uint32_t>(value);
    }

    // A typical segment (~8 s of Opus speech, ~16 KB), for the count of those on the card
    static constexpr uint64_t ESTIMATED_SEGMENT_BYTES = 32 * 1024;  // Opus 32 kbit/s

    Hot& _hot;
    SegmentLog* _card = nullptr;
    uint8_t* _staging = nullptr;
    size_t _stagingSize = 0;
    MoveCallback _onMove = nullptr;
    UnixClock _clock = nullptr;
    bool _fromCard = false;
};
