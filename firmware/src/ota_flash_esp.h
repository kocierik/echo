#pragma once

#include <esp_ota_ops.h>

#include "ota_receiver.h"

/** The inactive app partition (app0/app1 of default_8MB.csv), written as the image arrives. */
class EspOtaFlash : public OtaFlash {
public:
    uint32_t capacity() const override {
        const esp_partition_t* partition = esp_ota_get_next_update_partition(nullptr);
        return partition != nullptr ? partition->size : 0;
    }

    bool begin(uint32_t size) override {
        _partition = esp_ota_get_next_update_partition(nullptr);
        if (_partition == nullptr || size > _partition->size) return false;
        // Sectors are erased as the writes reach them: no long pause before the first chunk
        _open = esp_ota_begin(_partition, OTA_WITH_SEQUENTIAL_WRITES, &_handle) == ESP_OK;
        return _open;
    }

    bool write(const uint8_t* data, size_t length) override {
        return _open && esp_ota_write(_handle, data, length) == ESP_OK;
    }

    bool finish() override {
        if (!_open) return false;
        _open = false;  // esp_ota_end frees the handle, valid image or not
        return esp_ota_end(_handle) == ESP_OK && esp_ota_set_boot_partition(_partition) == ESP_OK;
    }

    void abort() override {
        if (!_open) return;
        _open = false;
        esp_ota_abort(_handle);
    }

private:
    const esp_partition_t* _partition = nullptr;
    esp_ota_handle_t _handle = 0;
    bool _open = false;
};
