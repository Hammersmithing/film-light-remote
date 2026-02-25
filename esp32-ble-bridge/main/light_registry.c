#include "light_registry.h"
#include <string.h>
#include "esp_log.h"

static const char *TAG = "light_reg";

static light_entry_t lights[MAX_LIGHTS];

void light_registry_init(void)
{
    memset(lights, 0, sizeof(lights));
    ESP_LOGI(TAG, "Light registry initialized (max %d)", MAX_LIGHTS);
}

light_entry_t *light_registry_add(const char *id, uint16_t unicast, const char *name)
{
    // Check if already registered
    light_entry_t *existing = light_registry_find_by_unicast(unicast);
    if (existing) {
        // Update existing entry
        strncpy(existing->id, id, sizeof(existing->id) - 1);
        strncpy(existing->name, name, sizeof(existing->name) - 1);
        ESP_LOGI(TAG, "Updated light unicast=0x%04X name=%s", unicast, name);
        return existing;
    }

    // Find empty slot
    for (int i = 0; i < MAX_LIGHTS; i++) {
        if (!lights[i].registered) {
            strncpy(lights[i].id, id, sizeof(lights[i].id) - 1);
            lights[i].unicast = unicast;
            strncpy(lights[i].name, name, sizeof(lights[i].name) - 1);
            lights[i].registered = true;
            lights[i].connected = false;
            lights[i].active_effect = NULL;
            ESP_LOGI(TAG, "Added light[%d] unicast=0x%04X name=%s", i, unicast, name);
            return &lights[i];
        }
    }

    ESP_LOGE(TAG, "No free slots for light unicast=0x%04X", unicast);
    return NULL;
}

light_entry_t *light_registry_find_by_unicast(uint16_t unicast)
{
    for (int i = 0; i < MAX_LIGHTS; i++) {
        if (lights[i].registered && lights[i].unicast == unicast) {
            return &lights[i];
        }
    }
    return NULL;
}

light_entry_t *light_registry_get_all(int *count)
{
    *count = MAX_LIGHTS;
    return lights;
}

void light_registry_remove(uint16_t unicast)
{
    for (int i = 0; i < MAX_LIGHTS; i++) {
        if (lights[i].registered && lights[i].unicast == unicast) {
            ESP_LOGI(TAG, "Removed light[%d] unicast=0x%04X", i, unicast);
            memset(&lights[i], 0, sizeof(light_entry_t));
            return;
        }
    }
}

void light_registry_clear(void)
{
    for (int i = 0; i < MAX_LIGHTS; i++) {
        if (lights[i].registered) {
            ESP_LOGI(TAG, "Clearing light[%d] unicast=0x%04X", i, lights[i].unicast);
        }
    }
    memset(lights, 0, sizeof(lights));
}
