#pragma once

#include "esp_err.h"

// Start the WebSocket server on port 8765
esp_err_t ws_server_start(void);

// Send a JSON string to the connected client
esp_err_t ws_server_send(const char *json_str);

// Send a formatted JSON event
esp_err_t ws_server_send_event(const char *event_type, const char *json_body);

// Check if a client is connected
bool ws_server_has_client(void);
