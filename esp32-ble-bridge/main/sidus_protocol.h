#pragma once

#include <stdint.h>
#include <stdbool.h>

// Build a 10-byte Sidus CCT payload.
// intensity: 0-100 percent, cct_kelvin: e.g. 5600, sleep_mode: 0 or 1
void sidus_build_cct(double intensity, int cct_kelvin, int sleep_mode, uint8_t out[10]);

// Build a 10-byte Sidus HSI payload.
void sidus_build_hsi(double intensity, int hue, int saturation, int cct_kelvin, int sleep_mode, uint8_t out[10]);

// Build a 10-byte Sidus Sleep payload.
// on=true means awake (sleepMode=1), on=false means sleep (sleepMode=0)
void sidus_build_sleep(bool on, uint8_t out[10]);

// Build a 10-byte Sidus Effect payload.
void sidus_build_effect(int effect_type, double intensity, int frq, int cct_kelvin,
                        int cop_car_color, int effect_mode, int hue, int saturation,
                        uint8_t out[10]);

// Build an 11-byte access message: [0x26] + 10-byte payload
void sidus_build_access_cct(double intensity, int cct_kelvin, int sleep_mode, uint8_t out[11]);
void sidus_build_access_hsi(double intensity, int hue, int saturation, int cct_kelvin, int sleep_mode, uint8_t out[11]);
void sidus_build_access_sleep(bool on, uint8_t out[11]);
void sidus_build_access_effect(int effect_type, double intensity, int frq, int cct_kelvin,
                               int cop_car_color, int effect_mode, int hue, int saturation,
                               uint8_t out[11]);
