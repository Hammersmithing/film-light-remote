#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_system.h"
#include "esp_log.h"
#include "nvs_flash.h"

#include "wifi.h"
#include "ws_server.h"
#include "ble_mesh.h"
#include "light_registry.h"
#include "effect_engine.h"

static const char *TAG = "main";

void app_main(void)
{
    ESP_LOGI(TAG, "=== Film Light Bridge v1.0 ===");

    // Initialize NVS (required for WiFi and BLE)
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // Initialize subsystems
    light_registry_init();
    effect_engine_init();

    // Initialize BLE
    ret = ble_mesh_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "BLE init failed: %s", esp_err_to_name(ret));
    }

    // Initialize WiFi
    ret = wifi_init_sta();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "WiFi connection failed, bridge will not be discoverable");
        // Could start soft-AP mode here as fallback
    }

    // Start mDNS advertisement
    if (wifi_is_connected()) {
        wifi_start_mdns();
    }

    // Start WebSocket server
    ret = ws_server_start();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "WebSocket server start failed: %s", esp_err_to_name(ret));
    }

    ESP_LOGI(TAG, "Bridge ready, waiting for phone connection on port 8765");

    // Main loop - just keep alive, everything is event-driven
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(10000));
    }
}
