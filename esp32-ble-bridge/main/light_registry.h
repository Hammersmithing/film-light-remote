#pragma once

#include <stdint.h>
#include <stdbool.h>

#define MAX_LIGHTS 9

typedef struct effect_instance effect_instance_t; // forward decl

typedef struct {
    char id[64];                // UUID string from phone
    uint16_t unicast;           // Mesh unicast address
    bool registered;            // Has been added via add_light
    bool connected;             // Reachable via mesh proxy
    char name[64];              // Human-readable name
    effect_instance_t *active_effect; // NULL if no effect running
} light_entry_t;

void light_registry_init(void);
light_entry_t *light_registry_add(const char *id, uint16_t unicast, const char *name);
light_entry_t *light_registry_find_by_unicast(uint16_t unicast);
light_entry_t *light_registry_get_all(int *count);
void light_registry_remove(uint16_t unicast);
void light_registry_clear(void);
