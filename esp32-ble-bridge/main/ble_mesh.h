#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"
#include "esp_gatt_defs.h"

// Initialize BLE GATT client
esp_err_t ble_mesh_init(void);

// Connect to a light by BLE MAC address
esp_err_t ble_mesh_connect(const uint8_t ble_addr[6]);

// Disconnect a light by GATT connection ID
esp_err_t ble_mesh_disconnect(uint16_t conn_id);

// Write a mesh proxy PDU to a specific light's 2ADD characteristic.
// conn_id and handle come from the light_registry.
esp_err_t ble_mesh_write(esp_gatt_if_t gattc_if, uint16_t conn_id, uint16_t handle,
                          const uint8_t *data, int len);

// Send a CCT command to a light via its unicast address
esp_err_t ble_mesh_send_cct(uint16_t unicast, double intensity, int cct_kelvin, int sleep_mode);

// Send an HSI command to a light
esp_err_t ble_mesh_send_hsi(uint16_t unicast, double intensity, int hue, int saturation,
                             int cct_kelvin, int sleep_mode);

// Send a sleep command to a light
esp_err_t ble_mesh_send_sleep(uint16_t unicast, bool on);

// Send a hardware effect command to a light
esp_err_t ble_mesh_send_effect(uint16_t unicast, int effect_type, double intensity, int frq,
                                int cct_kelvin, int cop_car_color, int effect_mode,
                                int hue, int saturation);
