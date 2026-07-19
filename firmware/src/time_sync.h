#pragma once

#include <Arduino.h>
#include <time.h>
#include <WiFi.h>
#include "config.h"

/**
 * NTP time synchronization module.
 * Syncs the ESP32 internal RTC with an NTP server after WiFi connects.
 */

// NTP Configuration
#define NTP_SERVER "pool.ntp.org"
#define NTP_GMT_OFFSET_SEC 0       // UTC (timezone handled by backend)
#define NTP_DAYLIGHT_OFFSET_SEC 0

class TimeSync {
public:
    /**
     * Initialize NTP sync. Call after WiFi is connected.
     * Blocks until time is synced or timeout.
     * @return true if time was synced successfully.
     */
    bool begin();

    /** Check if time has been synced at least once. */
    bool isSynced() const { return _synced; }

    /**
     * Get current time as ISO 8601 UTC string.
     * @param buffer Output buffer (min 30 chars).
     * @param bufSize Buffer size.
     */
    void getTimestamp(char* buffer, size_t bufSize);

    /** Re-sync with NTP server (call periodically, e.g. every hour). */
    void resync();

private:
    bool _synced = false;
    uint32_t _lastSyncMs = 0;
};

// Implementation

bool TimeSync::begin() {
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println("[NTP] WiFi not connected, skipping sync");
        return false;
    }

    Serial.println("[NTP] Syncing time...");
    configTime(NTP_GMT_OFFSET_SEC, NTP_DAYLIGHT_OFFSET_SEC, NTP_SERVER);

    // Wait for sync (max 5 seconds)
    struct tm timeinfo;
    uint32_t start = millis();
    while (!getLocalTime(&timeinfo) && (millis() - start < 5000)) {
        delay(100);
    }

    if (getLocalTime(&timeinfo)) {
        _synced = true;
        _lastSyncMs = millis();
        char buf[30];
        getTimestamp(buf, sizeof(buf));
        Serial.printf("[NTP] Time synced: %s\n", buf);
        return true;
    }

    Serial.println("[NTP] Sync failed (timeout)");
    return false;
}

void TimeSync::getTimestamp(char* buffer, size_t bufSize) {
    struct tm timeinfo;
    if (_synced && getLocalTime(&timeinfo)) {
        strftime(buffer, bufSize, "%Y-%m-%dT%H:%M:%SZ", &timeinfo);
    } else {
        // Fallback: millis-based approximation
        snprintf(buffer, bufSize, "1970-01-01T00:00:00Z");
    }
}

void TimeSync::resync() {
    // Re-sync every hour
    if (millis() - _lastSyncMs > 3600000) {
        begin();
    }
}
