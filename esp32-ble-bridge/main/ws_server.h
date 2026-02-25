#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

// Start the WebSocket server on port 8765
esp_err_t ws_server_start(void);

// Send a JSON string to the connected client
esp_err_t ws_server_send(const char *json_str);

// Send a formatted JSON event
esp_err_t ws_server_send_event(const char *event_type, const char *json_body);

// Check if a client is connected
bool ws_server_has_client(void);

// Notify phone about light connection status
void ws_server_notify_light_status(uint16_t unicast, bool connected);

// Notify phone about an error
void ws_server_notify_error(const char *message);
