#pragma once

#include <Arduino.h>
#include <HTTPClient.h>
#include <WiFi.h>
#include "config.h"

/**
 * HTTP client for sending ADPCM audio segments to the backend.
 * Handles multipart POST with proper headers and retry logic.
 */

struct SegmentMetadata {
    uint32_t durationMs;
    uint32_t silenceBeforeMs;
    char recordedAt[30];  // ISO 8601 timestamp
};

class HttpSender {
public:
    /**
     * Send an ADPCM audio segment to the backend.
     * @param data ADPCM audio bytes.
     * @param length Length of audio data.
     * @param meta Segment metadata.
     * @return true if sent successfully.
     */
    bool sendSegment(const uint8_t* data, size_t length, const SegmentMetadata& meta);

    /** Check if WiFi is connected. */
    bool isConnected() const { return WiFi.status() == WL_CONNECTED; }

    /** Get the ISO 8601 timestamp for "now". */
    static void getTimestamp(char* buffer, size_t bufSize);

private:
    bool doPost(const uint8_t* data, size_t length, const SegmentMetadata& meta);
};

// Implementation

bool HttpSender::sendSegment(const uint8_t* data, size_t length, const SegmentMetadata& meta) {
    if (!isConnected()) {
        Serial.println("[HTTP] Not connected to WiFi");
        return false;
    }

    for (int attempt = 0; attempt < HTTP_MAX_RETRIES; attempt++) {
        if (doPost(data, length, meta)) {
            return true;
        }
        Serial.printf("[HTTP] Attempt %d failed, retrying in %dms...\n",
                      attempt + 1, HTTP_RETRY_DELAY_MS);
        delay(HTTP_RETRY_DELAY_MS);
    }

    Serial.println("[HTTP] All retries failed");
    return false;
}

bool HttpSender::doPost(const uint8_t* data, size_t length, const SegmentMetadata& meta) {
    HTTPClient http;
    String url = String("http://") + SERVER_HOST + ":" + SERVER_PORT + SERVER_ENDPOINT;

    http.begin(url);
    http.setTimeout(HTTP_TIMEOUT_MS);

    // Build multipart body
    String boundary = "----EchoBoundary" + String(millis());
    String contentType = "multipart/form-data; boundary=" + boundary;

    http.addHeader("Content-Type", contentType);
    http.addHeader("X-API-Key", API_KEY);
    http.addHeader("X-Recorded-At", meta.recordedAt);
    http.addHeader("X-Duration-Ms", String(meta.durationMs));
    if (meta.silenceBeforeMs > 0) {
        http.addHeader("X-Silence-Before-Ms", String(meta.silenceBeforeMs));
    }

    // Build multipart body manually
    String bodyStart = "--" + boundary + "\r\n";
    bodyStart += "Content-Disposition: form-data; name=\"audio\"; filename=\"segment.adpcm\"\r\n";
    bodyStart += "Content-Type: application/octet-stream\r\n\r\n";

    String bodyEnd = "\r\n--" + boundary + "--\r\n";

    size_t totalLength = bodyStart.length() + length + bodyEnd.length();

    // Use a single buffer for the complete body
    uint8_t* body = (uint8_t*)malloc(totalLength);
    if (!body) {
        Serial.println("[HTTP] Failed to allocate body buffer");
        http.end();
        return false;
    }

    size_t offset = 0;
    memcpy(body + offset, bodyStart.c_str(), bodyStart.length());
    offset += bodyStart.length();
    memcpy(body + offset, data, length);
    offset += length;
    memcpy(body + offset, bodyEnd.c_str(), bodyEnd.length());

    int httpCode = http.POST(body, totalLength);
    free(body);

    if (httpCode == 201) {
        Serial.printf("[HTTP] Segment sent OK (%u bytes, %ums)\n", length, meta.durationMs);
        http.end();
        return true;
    }

    Serial.printf("[HTTP] POST failed: %d\n", httpCode);
    http.end();
    return false;
}

void HttpSender::getTimestamp(char* buffer, size_t bufSize) {
    // Simple timestamp without NTP (uses millis offset)
    // In production, sync with NTP for accurate timestamps
    unsigned long ms = millis();
    unsigned long seconds = ms / 1000;
    unsigned long minutes = seconds / 60;
    unsigned long hours = minutes / 60;

    // Format as basic ISO 8601 (approximate, should use NTP in production)
    snprintf(buffer, bufSize, "2026-01-01T%02lu:%02lu:%02luZ",
             hours % 24, minutes % 60, seconds % 60);
}
