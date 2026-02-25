#pragma once

#include <stdbool.h>
#include "esp_err.h"

// Initialize WiFi in station mode and connect.
// Falls back to soft-AP if no credentials stored.
esp_err_t wifi_init_sta(void);

// Start mDNS advertisement for _filmlightbridge._tcp
esp_err_t wifi_start_mdns(void);

// Check if WiFi is connected
bool wifi_is_connected(void);
