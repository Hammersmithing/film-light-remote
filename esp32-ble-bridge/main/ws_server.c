#include "ws_server.h"
#include <string.h>
#include "esp_log.h"
#include "esp_http_server.h"
#include "cJSON.h"

#include "mesh_crypto.h"
#include "sidus_protocol.h"
#include "ble_mesh.h"
#include "light_registry.h"
#include "effect_engine.h"

static const char *TAG = "ws_server";

static httpd_handle_t server = NULL;
static int ws_fd = -1;  // File descriptor of the connected WebSocket client

// Forward declarations
static void handle_command(cJSON *root);
static void handle_set_keys(cJSON *root);
static void handle_add_light(cJSON *root);
static void handle_connect(cJSON *root);
static void handle_disconnect(cJSON *root);
static void handle_set_cct(cJSON *root);
static void handle_set_hsi(cJSON *root);
static void handle_sleep(cJSON *root);
static void handle_set_effect(cJSON *root);
static void handle_start_effect(cJSON *root);
static void handle_update_effect(cJSON *root);
static void handle_stop_effect(cJSON *root);
static void handle_stop_all(void);

// Parse BLE address string "AA:BB:CC:DD:EE:FF" into 6 bytes
static bool parse_ble_addr(const char *str, uint8_t out[6])
{
    if (!str || strlen(str) < 17) return false;
    unsigned int b[6];
    if (sscanf(str, "%x:%x:%x:%x:%x:%x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) {
        return false;
    }
    for (int i = 0; i < 6; i++) out[i] = (uint8_t)b[i];
    return true;
}

// Parse hex string into bytes
static int parse_hex_string(const char *hex, uint8_t *out, int max_len)
{
    if (!hex) return 0;
    int len = strlen(hex);
    int byte_count = len / 2;
    if (byte_count > max_len) byte_count = max_len;
    for (int i = 0; i < byte_count; i++) {
        unsigned int b;
        if (sscanf(hex + i * 2, "%2x", &b) != 1) return i;
        out[i] = (uint8_t)b;
    }
    return byte_count;
}

// WebSocket handler
static esp_err_t ws_handler(httpd_req_t *req)
{
    if (req->method == HTTP_GET) {
        // New WebSocket connection
        ws_fd = httpd_req_to_sockfd(req);
        ESP_LOGI(TAG, "WebSocket client connected (fd=%d)", ws_fd);

        // Send ready event
        char ready_msg[128];
        snprintf(ready_msg, sizeof(ready_msg),
                 "{\"event\":\"ready\",\"version\":\"1.0\",\"max_lights\":%d}", MAX_LIGHTS);
        ws_server_send(ready_msg);
        return ESP_OK;
    }

    // Receive WebSocket frame
    httpd_ws_frame_t ws_pkt;
    memset(&ws_pkt, 0, sizeof(httpd_ws_frame_t));
    ws_pkt.type = HTTPD_WS_TYPE_TEXT;

    // Get frame length
    esp_err_t ret = httpd_ws_recv_frame(req, &ws_pkt, 0);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "httpd_ws_recv_frame failed to get length: %s", esp_err_to_name(ret));
        return ret;
    }

    if (ws_pkt.len == 0) return ESP_OK;

    // Allocate buffer and receive
    uint8_t *buf = calloc(1, ws_pkt.len + 1);
    if (!buf) {
        ESP_LOGE(TAG, "Failed to allocate %d bytes", (int)ws_pkt.len);
        return ESP_ERR_NO_MEM;
    }
    ws_pkt.payload = buf;

    ret = httpd_ws_recv_frame(req, &ws_pkt, ws_pkt.len);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "httpd_ws_recv_frame failed: %s", esp_err_to_name(ret));
        free(buf);
        return ret;
    }

    if (ws_pkt.type == HTTPD_WS_TYPE_TEXT) {
        ESP_LOGD(TAG, "RX: %s", (char *)ws_pkt.payload);
        cJSON *root = cJSON_Parse((char *)ws_pkt.payload);
        if (root) {
            handle_command(root);
            cJSON_Delete(root);
        } else {
            ESP_LOGE(TAG, "Failed to parse JSON");
        }
    } else if (ws_pkt.type == HTTPD_WS_TYPE_CLOSE) {
        ESP_LOGI(TAG, "WebSocket client disconnected");
        ws_fd = -1;
    }

    free(buf);
    return ESP_OK;
}

esp_err_t ws_server_start(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = 8765;
    config.max_open_sockets = 3;
    config.lru_purge_enable = true;

    esp_err_t ret = httpd_start(&server, &config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start HTTP server: %s", esp_err_to_name(ret));
        return ret;
    }

    // Register WebSocket URI handler
    httpd_uri_t ws_uri = {
        .uri = "/ws",
        .method = HTTP_GET,
        .handler = ws_handler,
        .is_websocket = true,
        .handle_ws_control_frames = true,
    };
    httpd_register_uri_handler(server, &ws_uri);

    ESP_LOGI(TAG, "WebSocket server started on port 8765, path /ws");
    return ESP_OK;
}

esp_err_t ws_server_send(const char *json_str)
{
    if (ws_fd < 0 || !server) {
        return ESP_ERR_INVALID_STATE;
    }

    httpd_ws_frame_t ws_pkt;
    memset(&ws_pkt, 0, sizeof(httpd_ws_frame_t));
    ws_pkt.payload = (uint8_t *)json_str;
    ws_pkt.len = strlen(json_str);
    ws_pkt.type = HTTPD_WS_TYPE_TEXT;

    esp_err_t ret = httpd_ws_send_frame_async(server, ws_fd, &ws_pkt);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to send WS frame: %s", esp_err_to_name(ret));
    }
    return ret;
}

esp_err_t ws_server_send_event(const char *event_type, const char *json_body)
{
    char buf[512];
    snprintf(buf, sizeof(buf), "{\"event\":\"%s\",%s}", event_type, json_body);
    return ws_server_send(buf);
}

bool ws_server_has_client(void)
{
    return ws_fd >= 0;
}

// Notify the phone about a light's connection status
void ws_server_notify_light_status(uint16_t unicast, bool connected)
{
    char buf[128];
    snprintf(buf, sizeof(buf),
             "{\"event\":\"light_status\",\"unicast\":%d,\"connected\":%s}",
             unicast, connected ? "true" : "false");
    ws_server_send(buf);
}

void ws_server_notify_error(const char *message)
{
    char buf[256];
    snprintf(buf, sizeof(buf), "{\"event\":\"error\",\"message\":\"%s\"}", message);
    ws_server_send(buf);
}

// MARK: - Command Dispatch

static void handle_command(cJSON *root)
{
    cJSON *cmd = cJSON_GetObjectItem(root, "cmd");
    if (!cmd || !cJSON_IsString(cmd)) {
        ESP_LOGE(TAG, "Missing 'cmd' field");
        return;
    }

    const char *cmd_str = cmd->valuestring;
    ESP_LOGI(TAG, "Command: %s", cmd_str);

    if (strcmp(cmd_str, "set_keys") == 0) {
        handle_set_keys(root);
    } else if (strcmp(cmd_str, "add_light") == 0) {
        handle_add_light(root);
    } else if (strcmp(cmd_str, "connect") == 0) {
        handle_connect(root);
    } else if (strcmp(cmd_str, "disconnect") == 0) {
        handle_disconnect(root);
    } else if (strcmp(cmd_str, "set_cct") == 0) {
        handle_set_cct(root);
    } else if (strcmp(cmd_str, "set_hsi") == 0) {
        handle_set_hsi(root);
    } else if (strcmp(cmd_str, "sleep") == 0) {
        handle_sleep(root);
    } else if (strcmp(cmd_str, "set_effect") == 0) {
        handle_set_effect(root);
    } else if (strcmp(cmd_str, "start_effect") == 0) {
        handle_start_effect(root);
    } else if (strcmp(cmd_str, "update_effect") == 0) {
        handle_update_effect(root);
    } else if (strcmp(cmd_str, "stop_effect") == 0) {
        handle_stop_effect(root);
    } else if (strcmp(cmd_str, "stop_all") == 0) {
        handle_stop_all();
    } else {
        ESP_LOGW(TAG, "Unknown command: %s", cmd_str);
    }
}

static void handle_set_keys(cJSON *root)
{
    cJSON *nk = cJSON_GetObjectItem(root, "network_key");
    cJSON *ak = cJSON_GetObjectItem(root, "app_key");
    cJSON *iv = cJSON_GetObjectItem(root, "iv_index");
    cJSON *src = cJSON_GetObjectItem(root, "src_address");

    if (!nk || !ak || !iv) {
        ESP_LOGE(TAG, "set_keys: missing fields");
        return;
    }

    uint8_t network_key[16], app_key[16];
    parse_hex_string(nk->valuestring, network_key, 16);
    parse_hex_string(ak->valuestring, app_key, 16);
    uint32_t iv_index = (uint32_t)iv->valuedouble;
    uint16_t src_addr = src ? (uint16_t)src->valueint : 0x0001;

    mesh_crypto_init(network_key, app_key, iv_index, src_addr);
    ESP_LOGI(TAG, "Mesh keys configured, iv_index=0x%08lX src=0x%04X",
             (unsigned long)iv_index, src_addr);
}

static void handle_add_light(cJSON *root)
{
    cJSON *id = cJSON_GetObjectItem(root, "id");
    cJSON *addr = cJSON_GetObjectItem(root, "ble_addr");
    cJSON *uni = cJSON_GetObjectItem(root, "unicast");
    cJSON *name = cJSON_GetObjectItem(root, "name");

    if (!id || !addr || !uni) {
        ESP_LOGE(TAG, "add_light: missing fields");
        return;
    }

    uint8_t ble_addr[6];
    if (!parse_ble_addr(addr->valuestring, ble_addr)) {
        ESP_LOGE(TAG, "add_light: invalid BLE address: %s", addr->valuestring);
        return;
    }

    light_registry_add(id->valuestring, ble_addr, (uint16_t)uni->valueint,
                       name ? name->valuestring : "");
}

static void handle_connect(cJSON *root)
{
    cJSON *uni = cJSON_GetObjectItem(root, "unicast");
    if (!uni) return;

    uint16_t unicast = (uint16_t)uni->valueint;
    light_entry_t *light = light_registry_find_by_unicast(unicast);
    if (!light) {
        ESP_LOGE(TAG, "connect: light 0x%04X not registered", unicast);
        ws_server_notify_error("Light not registered");
        return;
    }

    if (light->connected) {
        ESP_LOGI(TAG, "connect: light 0x%04X already connected", unicast);
        ws_server_notify_light_status(unicast, true);
        return;
    }

    ESP_LOGI(TAG, "Connecting to light 0x%04X...", unicast);
    ble_mesh_connect(light->ble_addr);
}

static void handle_disconnect(cJSON *root)
{
    cJSON *uni = cJSON_GetObjectItem(root, "unicast");
    if (!uni) return;

    uint16_t unicast = (uint16_t)uni->valueint;
    light_entry_t *light = light_registry_find_by_unicast(unicast);
    if (!light || !light->connected) return;

    // Stop any running effect
    effect_engine_stop(unicast);

    ble_mesh_disconnect(light->gattc_conn_id);
    light->connected = false;
    ws_server_notify_light_status(unicast, false);
}

static void handle_set_cct(cJSON *root)
{
    cJSON *uni = cJSON_GetObjectItem(root, "unicast");
    cJSON *intensity = cJSON_GetObjectItem(root, "intensity");
    cJSON *cct = cJSON_GetObjectItem(root, "cct_kelvin");
    cJSON *sleep = cJSON_GetObjectItem(root, "sleep_mode");

    if (!uni || !intensity || !cct) return;

    uint16_t unicast = (uint16_t)uni->valueint;
    int sleep_mode = sleep ? sleep->valueint : 1;

    ble_mesh_send_cct(unicast, intensity->valuedouble, cct->valueint, sleep_mode);
}

static void handle_set_hsi(cJSON *root)
{
    cJSON *uni = cJSON_GetObjectItem(root, "unicast");
    cJSON *intensity = cJSON_GetObjectItem(root, "intensity");
    cJSON *hue = cJSON_GetObjectItem(root, "hue");
    cJSON *sat = cJSON_GetObjectItem(root, "saturation");
    cJSON *cct = cJSON_GetObjectItem(root, "cct_kelvin");
    cJSON *sleep = cJSON_GetObjectItem(root, "sleep_mode");

    if (!uni || !intensity || !hue || !sat) return;

    uint16_t unicast = (uint16_t)uni->valueint;
    int cct_kelvin = cct ? cct->valueint : 5600;
    int sleep_mode = sleep ? sleep->valueint : 1;

    ble_mesh_send_hsi(unicast, intensity->valuedouble, hue->valueint, sat->valueint,
                      cct_kelvin, sleep_mode);
}

static void handle_sleep(cJSON *root)
{
    cJSON *uni = cJSON_GetObjectItem(root, "unicast");
    cJSON *on = cJSON_GetObjectItem(root, "on");

    if (!uni || !on) return;

    ble_mesh_send_sleep((uint16_t)uni->valueint, cJSON_IsTrue(on));
}

static void handle_set_effect(cJSON *root)
{
    cJSON *uni = cJSON_GetObjectItem(root, "unicast");
    cJSON *type = cJSON_GetObjectItem(root, "effect_type");
    cJSON *intensity = cJSON_GetObjectItem(root, "intensity");
    cJSON *frq = cJSON_GetObjectItem(root, "frequency");
    cJSON *cct = cJSON_GetObjectItem(root, "cct_kelvin");
    cJSON *color = cJSON_GetObjectItem(root, "cop_car_color");
    cJSON *mode = cJSON_GetObjectItem(root, "effect_mode");
    cJSON *hue = cJSON_GetObjectItem(root, "hue");
    cJSON *sat = cJSON_GetObjectItem(root, "saturation");

    if (!uni || !type) return;

    ble_mesh_send_effect(
        (uint16_t)uni->valueint,
        type->valueint,
        intensity ? intensity->valuedouble : 50.0,
        frq ? frq->valueint : 8,
        cct ? cct->valueint : 5600,
        color ? color->valueint : 0,
        mode ? mode->valueint : 0,
        hue ? hue->valueint : 0,
        sat ? sat->valueint : 100
    );
}

static void handle_start_effect(cJSON *root)
{
    cJSON *uni = cJSON_GetObjectItem(root, "unicast");
    cJSON *engine = cJSON_GetObjectItem(root, "engine");
    cJSON *params = cJSON_GetObjectItem(root, "params");

    if (!uni || !engine) return;

    uint16_t unicast = (uint16_t)uni->valueint;
    const char *engine_name = engine->valuestring;

    // Map engine name to effect type
    effect_type_t etype = EFFECT_NONE;
    if (strcmp(engine_name, "pulsing") == 0) etype = EFFECT_PULSING;
    else if (strcmp(engine_name, "strobe") == 0) etype = EFFECT_STROBE;
    else if (strcmp(engine_name, "fire") == 0) etype = EFFECT_FIRE;
    else if (strcmp(engine_name, "candle") == 0) etype = EFFECT_CANDLE;
    else if (strcmp(engine_name, "lightning") == 0) etype = EFFECT_LIGHTNING;
    else if (strcmp(engine_name, "tv") == 0) etype = EFFECT_TV_FLICKER;
    else if (strcmp(engine_name, "party") == 0) etype = EFFECT_PARTY;
    else if (strcmp(engine_name, "explosion") == 0) etype = EFFECT_EXPLOSION;
    else if (strcmp(engine_name, "welding") == 0) etype = EFFECT_WELDING;
    else if (strcmp(engine_name, "faulty_bulb") == 0) etype = EFFECT_FAULTY_BULB;
    else if (strcmp(engine_name, "paparazzi") == 0) etype = EFFECT_PAPARAZZI;
    else {
        ESP_LOGW(TAG, "Unknown engine: %s", engine_name);
        return;
    }

    // Parse parameters
    effect_params_t ep = {0};
    effect_params_from_json(&ep, engine_name, params);

    // Stop any existing effect on this light
    effect_engine_stop(unicast);

    // Start new effect
    effect_engine_start(unicast, etype, &ep);
    ESP_LOGI(TAG, "Started %s effect on unicast 0x%04X", engine_name, unicast);
}

static void handle_update_effect(cJSON *root)
{
    cJSON *uni = cJSON_GetObjectItem(root, "unicast");
    cJSON *params = cJSON_GetObjectItem(root, "params");

    if (!uni || !params) return;

    uint16_t unicast = (uint16_t)uni->valueint;

    // Parse partial params and merge
    effect_params_t ep = {0};
    effect_params_from_json(&ep, NULL, params);
    effect_engine_update(unicast, &ep);
}

static void handle_stop_effect(cJSON *root)
{
    cJSON *uni = cJSON_GetObjectItem(root, "unicast");
    if (!uni) return;

    effect_engine_stop((uint16_t)uni->valueint);
}

static void handle_stop_all(void)
{
    effect_engine_stop_all();

    // Disconnect all lights
    int count;
    light_entry_t *all = light_registry_get_all(&count);
    for (int i = 0; i < count; i++) {
        if (all[i].registered && all[i].connected) {
            ble_mesh_disconnect(all[i].gattc_conn_id);
            all[i].connected = false;
            ws_server_notify_light_status(all[i].unicast, false);
        }
    }
}
