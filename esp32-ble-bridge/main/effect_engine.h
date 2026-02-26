#pragma once

#include <stdint.h>
#include <stdbool.h>

// Effect types (matches LightEffect enum raw values)
typedef enum {
    EFFECT_NONE = 0,
    EFFECT_PAPARAZZI = 1,
    EFFECT_LIGHTNING = 2,
    EFFECT_TV_FLICKER = 3,
    EFFECT_CANDLE = 4,
    EFFECT_FIRE = 5,
    EFFECT_STROBE = 6,
    EFFECT_EXPLOSION = 7,
    EFFECT_FAULTY_BULB = 8,
    EFFECT_PULSING = 9,
    EFFECT_WELDING = 10,
    EFFECT_PARTY = 13,
} effect_type_t;

// Color mode
typedef enum {
    COLOR_MODE_CCT = 0,
    COLOR_MODE_HSI = 1,
} color_mode_t;

// Effect parameters (superset of all engine params)
typedef struct {
    color_mode_t color_mode;
    double intensity;
    int cct_kelvin;
    int hue;
    int saturation;
    int hsi_cct;
    double frequency;
    // Pulsing
    double pulsing_min;
    double pulsing_max;
    double pulsing_shape;
    // Strobe
    double strobe_hz;
    // Faulty bulb
    double faulty_min;
    double faulty_max;
    double faulty_bias;
    double faulty_recovery;
    double faulty_warmth;
    int faulty_warmest_cct;
    int faulty_points;
    double faulty_transition;
    double faulty_frequency;
    // Party
    double party_colors[32];
    int party_color_count;
    double party_transition;
    double party_hue_bias;
} effect_params_t;

// Effect instance (one per running effect per light)
struct effect_instance {
    uint16_t unicast;
    effect_type_t type;
    effect_params_t params;
    // Runtime state
    double current_intensity;
    double phase_time;
    bool strobe_on;
    bool strobe_running;
    int party_color_index;
    int weld_remaining;
    void *timer;  // esp_timer_handle_t
    bool running;
};

typedef struct effect_instance effect_instance_t;

// Initialize effect engine system
void effect_engine_init(void);

// Start an effect on a light
effect_instance_t *effect_engine_start(uint16_t unicast, effect_type_t type, const effect_params_t *params);

// Update parameters on a running effect
void effect_engine_update(uint16_t unicast, const effect_params_t *params);

// Stop effect on a specific light
void effect_engine_stop(uint16_t unicast);

// Stop all running effects
void effect_engine_stop_all(void);

// Parse effect parameters from JSON fields into an effect_params_t
void effect_params_from_json(effect_params_t *params, const char *engine_name,
                              const void *json_params);
