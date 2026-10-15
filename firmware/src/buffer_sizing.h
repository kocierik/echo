#pragma once

#include <cstddef>

/**
 * How much PSRAM the audio ring buffer takes: up to `wanted`, leaving `reserve` free for
 * what is allocated later (the camera's frame buffer at each photo). 0 when even
 * `minimum` does not fit, so the firmware stops instead of running without a buffer.
 */
inline size_t chooseBufferCapacity(size_t wanted, size_t largestFree, size_t reserve,
                                   size_t minimum) {
    if (largestFree <= reserve) return 0;
    const size_t available = largestFree - reserve;
    const size_t capacity = available < wanted ? available : wanted;
    return capacity >= minimum ? capacity : 0;
}
