#include "ble_mesh.h"
#include <string.h>
#include "esp_log.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gattc_api.h"
#include "esp_gatt_defs.h"
#include "esp_gatt_common_api.h"

#include "mesh_crypto.h"
#include "sidus_protocol.h"
#include "light_registry.h"
#include "ws_server.h"

static const char *TAG = "ble_mesh";

// Mesh Proxy Service UUID: 0x1828
static esp_bt_uuid_t mesh_proxy_service_uuid = {
    .len = ESP_UUID_LEN_16,
    .uuid.uuid16 = 0x1828,
};

// Mesh Proxy Data In (write): 0x2ADD
static esp_bt_uuid_t mesh_proxy_data_in_uuid = {
    .len = ESP_UUID_LEN_16,
    .uuid.uuid16 = 0x2ADD,
};

// Mesh Proxy Data Out (notify): 0x2ADE
static esp_bt_uuid_t mesh_proxy_data_out_uuid = {
    .len = ESP_UUID_LEN_16,
    .uuid.uuid16 = 0x2ADE,
};

#define GATTC_APP_ID 0
#define INVALID_HANDLE 0

// Shared mesh proxy connection state
static bool s_proxy_connected = false;
static bool s_scan_for_proxy = false;
static esp_gatt_if_t s_gattc_if = ESP_GATT_IF_NONE;
static uint16_t s_proxy_conn_id = 0xFFFF;
static uint16_t s_proxy_data_in_handle = INVALID_HANDLE;
static uint8_t s_proxy_addr[6];  // BLE address of connected proxy

// Forward declarations
static void gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param);
static void gattc_event_handler(esp_gattc_cb_event_t event, esp_gatt_if_t gattc_if,
                                 esp_ble_gattc_cb_param_t *param);
static void handle_connect_event(esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param);
static void handle_disconnect_event(esp_ble_gattc_cb_param_t *param);
static void handle_search_result(esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param);
static void handle_search_complete(esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param);
static void handle_reg_for_notify(esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param);
static void notify_all_registered_lights(bool connected);

// Check if advertisement contains mesh proxy service (0x1828)
static bool adv_has_mesh_proxy_service(uint8_t *adv_data, uint8_t adv_len)
{
    int offset = 0;
    while (offset < adv_len) {
        uint8_t field_len = adv_data[offset];
        if (field_len == 0 || offset + field_len >= adv_len) break;

        uint8_t field_type = adv_data[offset + 1];

        // Complete or incomplete list of 16-bit service UUIDs
        if (field_type == 0x02 || field_type == 0x03) {
            for (int i = 2; i + 1 <= field_len; i += 2) {
                uint16_t uuid16 = adv_data[offset + i] | (adv_data[offset + i + 1] << 8);
                if (uuid16 == 0x1828) return true;
            }
        }

        offset += field_len + 1;
    }
    return false;
}

// Send proxy filter setup to establish mesh context
static void send_proxy_filter_setup(void)
{
    uint8_t pdu[64];
    int len = mesh_crypto_create_proxy_filter_setup(pdu, sizeof(pdu));
    if (len > 0 && s_proxy_data_in_handle != INVALID_HANDLE) {
        esp_ble_gattc_write_char(s_gattc_if, s_proxy_conn_id,
                                  s_proxy_data_in_handle,
                                  len, pdu,
                                  ESP_GATT_WRITE_TYPE_NO_RSP,
                                  ESP_GATT_AUTH_REQ_NONE);
        ESP_LOGI(TAG, "Sent proxy filter setup");
    }
}

// GAP callback — scan for mesh proxy service advertisements
static void gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param)
{
    switch (event) {
    case ESP_GAP_BLE_SCAN_RESULT_EVT:
        if (param->scan_rst.search_evt == ESP_GAP_SEARCH_INQ_RES_EVT && s_scan_for_proxy) {
            // Check if this device advertises mesh proxy service 0x1828
            if (adv_has_mesh_proxy_service(param->scan_rst.ble_adv,
                                            param->scan_rst.adv_data_len)) {
                ESP_LOGI(TAG, "Found mesh proxy %02X:%02X:%02X:%02X:%02X:%02X, connecting...",
                         param->scan_rst.bda[0], param->scan_rst.bda[1],
                         param->scan_rst.bda[2], param->scan_rst.bda[3],
                         param->scan_rst.bda[4], param->scan_rst.bda[5]);
                s_scan_for_proxy = false;
                memcpy(s_proxy_addr, param->scan_rst.bda, 6);
                esp_ble_gap_stop_scanning();
                esp_ble_gattc_open(s_gattc_if, param->scan_rst.bda,
                                    param->scan_rst.ble_addr_type, true);
            }
        }
        break;

    case ESP_GAP_BLE_SCAN_STOP_COMPLETE_EVT:
        ESP_LOGD(TAG, "Scan stopped");
        break;

    default:
        break;
    }
}

// GATTC callback
static void gattc_event_handler(esp_gattc_cb_event_t event, esp_gatt_if_t gattc_if,
                                 esp_ble_gattc_cb_param_t *param)
{
    switch (event) {
    case ESP_GATTC_REG_EVT:
        if (param->reg.status == ESP_GATT_OK) {
            s_gattc_if = gattc_if;
            ESP_LOGI(TAG, "GATTC registered, if=%d", gattc_if);
        }
        break;

    case ESP_GATTC_OPEN_EVT:
    case ESP_GATTC_CONNECT_EVT:
        handle_connect_event(gattc_if, param);
        break;

    case ESP_GATTC_CLOSE_EVT:
    case ESP_GATTC_DISCONNECT_EVT:
        handle_disconnect_event(param);
        break;

    case ESP_GATTC_SEARCH_RES_EVT:
        handle_search_result(gattc_if, param);
        break;

    case ESP_GATTC_SEARCH_CMPL_EVT:
        handle_search_complete(gattc_if, param);
        break;

    case ESP_GATTC_REG_FOR_NOTIFY_EVT:
        handle_reg_for_notify(gattc_if, param);
        break;

    case ESP_GATTC_NOTIFY_EVT:
        ESP_LOGD(TAG, "Notify from conn=%d handle=%d len=%d",
                 param->notify.conn_id, param->notify.handle, param->notify.value_len);
        break;

    default:
        break;
    }
}

static void handle_connect_event(esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param)
{
    if (param->open.status != ESP_GATT_OK) {
        ESP_LOGE(TAG, "Proxy connection failed, status=%d", param->open.status);
        ws_server_notify_error("BLE proxy connection failed");
        return;
    }

    s_proxy_conn_id = param->open.conn_id;
    ESP_LOGI(TAG, "Proxy connected, conn_id=%d", s_proxy_conn_id);

    // Request larger MTU for mesh PDUs
    esp_ble_gattc_send_mtu_req(gattc_if, s_proxy_conn_id);

    // Start service discovery
    esp_ble_gattc_search_service(gattc_if, s_proxy_conn_id, &mesh_proxy_service_uuid);
}

static void handle_disconnect_event(esp_ble_gattc_cb_param_t *param)
{
    ESP_LOGI(TAG, "Proxy disconnected, conn_id=%d reason=%d",
             param->disconnect.conn_id, param->disconnect.reason);

    s_proxy_connected = false;
    s_proxy_conn_id = 0xFFFF;
    s_proxy_data_in_handle = INVALID_HANDLE;

    // Notify all registered lights as disconnected
    notify_all_registered_lights(false);
}

static void handle_search_result(esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param)
{
    ESP_LOGI(TAG, "Service found: conn_id=%d uuid_len=%d",
             param->search_res.conn_id, param->search_res.srvc_id.uuid.len);

    if (param->search_res.srvc_id.uuid.len == ESP_UUID_LEN_16 &&
        param->search_res.srvc_id.uuid.uuid.uuid16 == 0x1828) {
        ESP_LOGI(TAG, "Found Mesh Proxy Service (0x1828)");
    }
}

static void handle_search_complete(esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param)
{
    ESP_LOGI(TAG, "Service discovery complete for conn_id=%d", param->search_cmpl.conn_id);

    // Get characteristic handles for 2ADD and 2ADE
    uint16_t count = 0;
    esp_gatt_status_t status = esp_ble_gattc_get_attr_count(
        gattc_if, s_proxy_conn_id, ESP_GATT_DB_CHARACTERISTIC,
        0x0001, 0xFFFF, INVALID_HANDLE, &count);

    if (status != ESP_GATT_OK || count == 0) {
        ESP_LOGE(TAG, "No characteristics found");
        return;
    }

    esp_gattc_char_elem_t *char_elems = malloc(sizeof(esp_gattc_char_elem_t) * count);
    if (!char_elems) return;

    // Find 2ADD (Proxy Data In)
    uint16_t char_count = count;
    status = esp_ble_gattc_get_char_by_uuid(
        gattc_if, s_proxy_conn_id, 0x0001, 0xFFFF,
        mesh_proxy_data_in_uuid, char_elems, &char_count);

    if (status == ESP_GATT_OK && char_count > 0) {
        s_proxy_data_in_handle = char_elems[0].char_handle;
        ESP_LOGI(TAG, "Found 2ADD handle=%d", s_proxy_data_in_handle);
    }

    // Find 2ADE (Proxy Data Out) and register for notifications
    char_count = count;
    status = esp_ble_gattc_get_char_by_uuid(
        gattc_if, s_proxy_conn_id, 0x0001, 0xFFFF,
        mesh_proxy_data_out_uuid, char_elems, &char_count);

    if (status == ESP_GATT_OK && char_count > 0) {
        uint16_t notify_handle = char_elems[0].char_handle;
        ESP_LOGI(TAG, "Found 2ADE handle=%d, registering for notify", notify_handle);
        esp_ble_gattc_register_for_notify(gattc_if, s_proxy_addr, notify_handle);
    }

    free(char_elems);

    // Mark proxy as connected and send filter setup
    if (s_proxy_data_in_handle != INVALID_HANDLE) {
        s_proxy_connected = true;
        send_proxy_filter_setup();

        // All registered lights are now reachable through mesh
        notify_all_registered_lights(true);
        ESP_LOGI(TAG, "Mesh proxy ready — all lights reachable");
    }
}

static void handle_reg_for_notify(esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param)
{
    if (param->reg_for_notify.status != ESP_GATT_OK) {
        ESP_LOGE(TAG, "Register for notify failed: %d", param->reg_for_notify.status);
        return;
    }
    ESP_LOGD(TAG, "Registered for notify on handle=%d", param->reg_for_notify.handle);

    // Enable notifications by writing to CCC descriptor
    uint16_t notify_en = 1;
    esp_ble_gattc_write_char_descr(
        gattc_if, s_proxy_conn_id,
        param->reg_for_notify.handle + 1,  // CCC descriptor is typically handle+1
        sizeof(notify_en), (uint8_t *)&notify_en,
        ESP_GATT_WRITE_TYPE_RSP, ESP_GATT_AUTH_REQ_NONE);
}

// Notify all registered lights as connected/disconnected
static void notify_all_registered_lights(bool connected)
{
    int count;
    light_entry_t *all = light_registry_get_all(&count);
    for (int i = 0; i < count; i++) {
        if (all[i].registered) {
            all[i].connected = connected;
            ws_server_notify_light_status(all[i].unicast, connected);
        }
    }
}

// Public API

esp_err_t ble_mesh_init(void)
{
    ESP_LOGI(TAG, "Initializing BLE...");

    esp_err_t ret;

    // Release classic BT memory
    ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));

    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ret = esp_bt_controller_init(&bt_cfg);
    if (ret) {
        ESP_LOGE(TAG, "BT controller init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    if (ret) {
        ESP_LOGE(TAG, "BT controller enable failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_bluedroid_init();
    if (ret) {
        ESP_LOGE(TAG, "Bluedroid init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_bluedroid_enable();
    if (ret) {
        ESP_LOGE(TAG, "Bluedroid enable failed: %s", esp_err_to_name(ret));
        return ret;
    }

    // Register callbacks
    ret = esp_ble_gap_register_callback(gap_event_handler);
    if (ret) {
        ESP_LOGE(TAG, "GAP register failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_ble_gattc_register_callback(gattc_event_handler);
    if (ret) {
        ESP_LOGE(TAG, "GATTC register failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_ble_gattc_app_register(GATTC_APP_ID);
    if (ret) {
        ESP_LOGE(TAG, "GATTC app register failed: %s", esp_err_to_name(ret));
        return ret;
    }

    // Set preferred MTU
    esp_ble_gatt_set_local_mtu(185);

    ESP_LOGI(TAG, "BLE initialized successfully");
    return ESP_OK;
}

esp_err_t ble_mesh_connect_proxy(void)
{
    if (s_proxy_connected) {
        ESP_LOGI(TAG, "Proxy already connected");
        notify_all_registered_lights(true);
        return ESP_OK;
    }

    s_scan_for_proxy = true;

    ESP_LOGI(TAG, "Scanning for mesh proxy nodes (0x1828)...");

    esp_ble_scan_params_t scan_params = {
        .scan_type = BLE_SCAN_TYPE_ACTIVE,
        .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
        .scan_filter_policy = BLE_SCAN_FILTER_ALLOW_ALL,
        .scan_interval = 0x50,
        .scan_window = 0x30,
        .scan_duplicate = BLE_SCAN_DUPLICATE_DISABLE,
    };

    esp_ble_gap_set_scan_params(&scan_params);
    return esp_ble_gap_start_scanning(15);  // 15 second timeout
}

bool ble_mesh_is_proxy_connected(void)
{
    return s_proxy_connected;
}

esp_err_t ble_mesh_disconnect_proxy(void)
{
    if (!s_proxy_connected) return ESP_OK;
    ESP_LOGI(TAG, "Disconnecting proxy conn_id=%d", s_proxy_conn_id);
    return esp_ble_gattc_close(s_gattc_if, s_proxy_conn_id);
}

esp_err_t ble_mesh_write(esp_gatt_if_t gattc_if, uint16_t conn_id, uint16_t handle,
                          const uint8_t *data, int len)
{
    if (handle == INVALID_HANDLE) return ESP_ERR_INVALID_STATE;

    return esp_ble_gattc_write_char(gattc_if, conn_id, handle,
                                     len, (uint8_t *)data,
                                     ESP_GATT_WRITE_TYPE_NO_RSP,
                                     ESP_GATT_AUTH_REQ_NONE);
}

// Build mesh PDU and write via shared proxy connection
static esp_err_t send_mesh_pdu(uint16_t unicast, const uint8_t *access_msg, int access_len)
{
    if (!s_proxy_connected) {
        ESP_LOGW(TAG, "Proxy not connected, cannot send to 0x%04X", unicast);
        return ESP_ERR_INVALID_STATE;
    }

    uint8_t pdu[64];
    int pdu_len = mesh_crypto_create_standard_pdu(access_msg, access_len, unicast, pdu, sizeof(pdu));
    if (pdu_len <= 0) {
        ESP_LOGE(TAG, "Failed to create mesh PDU for 0x%04X", unicast);
        return ESP_FAIL;
    }

    return ble_mesh_write(s_gattc_if, s_proxy_conn_id,
                           s_proxy_data_in_handle, pdu, pdu_len);
}

esp_err_t ble_mesh_send_cct(uint16_t unicast, double intensity, int cct_kelvin, int sleep_mode)
{
    uint8_t access_msg[11];
    sidus_build_access_cct(intensity, cct_kelvin, sleep_mode, access_msg);
    return send_mesh_pdu(unicast, access_msg, 11);
}

esp_err_t ble_mesh_send_hsi(uint16_t unicast, double intensity, int hue, int saturation,
                             int cct_kelvin, int sleep_mode)
{
    uint8_t access_msg[11];
    sidus_build_access_hsi(intensity, hue, saturation, cct_kelvin, sleep_mode, access_msg);
    return send_mesh_pdu(unicast, access_msg, 11);
}

esp_err_t ble_mesh_send_sleep(uint16_t unicast, bool on)
{
    uint8_t access_msg[11];
    sidus_build_access_sleep(on, access_msg);
    return send_mesh_pdu(unicast, access_msg, 11);
}

esp_err_t ble_mesh_send_effect(uint16_t unicast, int effect_type, double intensity, int frq,
                                int cct_kelvin, int cop_car_color, int effect_mode,
                                int hue, int saturation)
{
    uint8_t access_msg[11];
    sidus_build_access_effect(effect_type, intensity, frq, cct_kelvin,
                              cop_car_color, effect_mode, hue, saturation, access_msg);
    return send_mesh_pdu(unicast, access_msg, 11);
}
