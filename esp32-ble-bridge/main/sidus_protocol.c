/*
 * sidus_protocol.c — C port of SidusProtocols.swift for ESP32
 *
 * Builds 10-byte Sidus BLE payloads using the same bit-packing approach
 * as the Swift original:
 *   1. Build segments as reversed binary strings (LSB-first per segment)
 *   2. Concatenate all reversed segments
 *   3. Convert to 10 bytes, reversing bits within each byte
 *   4. Byte 0 = checksum (sum of bytes 1..9)
 */

#include "sidus_protocol.h"
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include "esp_log.h"

static const char *TAG = "sidus_proto";

// ---------------------------------------------------------------------------
// Bit-packing helpers
// ---------------------------------------------------------------------------

/// Append `width` bits of `value` (MSB-first) into `bits[]` starting at `*pos`,
/// then reverse the segment in place (to match Swift's "reversed()" per segment).
static void append_segment(uint8_t bits[], int *pos, int value, int width)
{
    int start = *pos;

    // Write MSB-first
    for (int i = width - 1; i >= 0; i--) {
        bits[start + (width - 1 - i)] = (value >> i) & 1;
    }

    // Reverse the segment in place (matches Swift: String(bit.reversed()))
    for (int i = 0; i < width / 2; i++) {
        uint8_t tmp = bits[start + i];
        bits[start + i] = bits[start + width - 1 - i];
        bits[start + width - 1 - i] = tmp;
    }

    *pos += width;
}

/// Convert 80 bits -> 10 bytes.  Within each byte the bits are reversed
/// (LSB first), then byte 0 is replaced with a checksum of bytes 1..9.
static void bits_to_10bytes(const uint8_t bits[80], uint8_t out[10])
{
    for (int i = 0; i < 10; i++) {
        uint8_t byte = 0;
        // Read 8 bits for this byte, but reverse bit order (match Swift)
        for (int b = 0; b < 8; b++) {
            if (bits[i * 8 + b]) {
                byte |= (1 << (7 - b));  // reversed: bit 0 of segment -> bit 7 of byte
            }
        }
        // The Swift code does: String(byteString.reversed()) then parses as binary.
        // byteString is the 8-char slice, reversed() flips it, then parsed MSB-first.
        // That is equivalent to reading the bits in reverse order within the byte.
        // Let me re-derive:
        //   bitString slice for byte i = bits[i*8 .. i*8+7]  (characters)
        //   reversed slice = bits[i*8+7], bits[i*8+6], ..., bits[i*8+0]
        //   parse reversed slice as binary MSB-first:
        //     bit[i*8+7]*128 + bit[i*8+6]*64 + ... + bit[i*8+0]*1
        // So bit at position i*8+0 has weight 1 (LSB), bit at i*8+7 has weight 128 (MSB).
        byte = 0;
        for (int b = 0; b < 8; b++) {
            if (bits[i * 8 + b]) {
                byte |= (1 << b);
            }
        }
        out[i] = byte;
    }

    // Checksum: byte 0 = sum of bytes 1..9 (unsigned wrap)
    uint8_t checksum = 0;
    for (int i = 1; i < 10; i++) {
        checksum += out[i];
    }
    out[0] = checksum;
}

// ---------------------------------------------------------------------------
// GM / CCT helper computations (matches Swift computeGM / computeCCTValue)
// ---------------------------------------------------------------------------

static void compute_gm(int gm_flag, int gm, int *gm_high_out, int *gm_value_out)
{
    int gm_high = 0;
    int gm_value = gm;
    if (gm_flag == 0) {
        gm_high = 0;
        gm_value = (int)round((double)gm / 10.0);
    } else {
        if (gm_value > 100) {
            gm_high = 1;
            gm_value -= 100;
        } else {
            gm_high = 0;
        }
    }
    *gm_high_out = gm_high;
    *gm_value_out = gm_value;
}

/// Compute the CCT field value from cct (= kelvin/10).
/// Matches Swift: cctValue = cct*10; if >10000 subtract 10000; /= 10
static int compute_cct_value(int cct)
{
    int v = cct * 10;
    if (v > 10000) v -= 10000;
    return v / 10;
}

// ---------------------------------------------------------------------------
// Clamp helpers
// ---------------------------------------------------------------------------

static int clamp_int(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

// ---------------------------------------------------------------------------
// CCT Protocol (commandType = 2)
// ---------------------------------------------------------------------------

void sidus_build_cct(double intensity_pct, int cct_kelvin, int sleep_mode, uint8_t out[10])
{
    int intensity = (int)round(intensity_pct * 10.0);  // 0-1000
    intensity = clamp_int(intensity, 0, 1000);
    int cct = cct_kelvin / 10;
    cct = clamp_int(cct, 180, 2000);
    int gm = 100;
    int gm_flag = 0;
    int auto_patch = 0;
    int command_type = 2;

    uint8_t bits[80];
    memset(bits, 0, sizeof(bits));
    int pos = 0;

    append_segment(bits, &pos, 0, 8);                                   // Reserved
    append_segment(bits, &pos, sleep_mode, 1);                          // Sleep mode
    append_segment(bits, &pos, 0, 20);                                  // Reserved
    append_segment(bits, &pos, 0, 12);                                  // Reserved
    append_segment(bits, &pos, auto_patch, 1);                          // Auto patch
    append_segment(bits, &pos, (cct * 10 <= 10000) ? 0 : 1, 1);        // CCT high flag
    append_segment(bits, &pos, gm_flag, 1);                             // GM flag

    int gm_high, gm_value;
    compute_gm(gm_flag, gm, &gm_high, &gm_value);

    append_segment(bits, &pos, gm_high, 1);                             // GM high
    append_segment(bits, &pos, gm_value, 7);                            // GM value

    int cct_value = compute_cct_value(cct);
    append_segment(bits, &pos, cct_value, 10);                          // CCT
    append_segment(bits, &pos, intensity, 10);                          // Intensity
    append_segment(bits, &pos, command_type, 7);                        // Command type
    append_segment(bits, &pos, 1, 1);                                   // Always 1

    bits_to_10bytes(bits, out);

    ESP_LOGD(TAG, "CCT: int=%d cct=%dK sleep=%d -> %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
             intensity, cct_kelvin, sleep_mode,
             out[0], out[1], out[2], out[3], out[4],
             out[5], out[6], out[7], out[8], out[9]);
}

// ---------------------------------------------------------------------------
// HSI Protocol (commandType = 1)
// ---------------------------------------------------------------------------

void sidus_build_hsi(double intensity_pct, int hue, int saturation, int cct_kelvin, int sleep_mode, uint8_t out[10])
{
    int intensity = (int)round(intensity_pct * 10.0);  // 0-1000
    intensity = clamp_int(intensity, 0, 1000);
    hue = clamp_int(hue, 0, 360);
    int sat = clamp_int(saturation, 0, 100);
    int cct = cct_kelvin / 50;   // Protocol field = Kelvin / 50
    int gm = 100;
    int gm_flag = 0;
    int auto_patch = 0;
    int command_type = 1;

    uint8_t bits[80];
    memset(bits, 0, sizeof(bits));
    int pos = 0;

    append_segment(bits, &pos, 0, 8);                                   // Reserved
    append_segment(bits, &pos, sleep_mode, 1);                          // Sleep mode
    append_segment(bits, &pos, 0, 18);                                  // Reserved
    append_segment(bits, &pos, auto_patch, 1);                          // Auto patch
    append_segment(bits, &pos, (cct * 50 <= 10000) ? 0 : 1, 1);        // CCT high flag
    append_segment(bits, &pos, gm_flag, 1);                             // GM flag

    int gm_high, gm_value;
    compute_gm(gm_flag, gm, &gm_high, &gm_value);

    append_segment(bits, &pos, gm_high, 1);                             // GM high
    append_segment(bits, &pos, gm_value, 7);                            // GM value

    // CCT value for HSI
    int cct_value = cct * 50;
    if (cct_value > 10000) cct_value -= 10000;
    cct_value = cct_value / 50;

    append_segment(bits, &pos, cct_value, 8);                           // CCT
    append_segment(bits, &pos, sat, 7);                                 // Saturation
    append_segment(bits, &pos, hue, 9);                                 // Hue
    append_segment(bits, &pos, intensity, 10);                          // Intensity
    append_segment(bits, &pos, command_type, 7);                        // Command type
    append_segment(bits, &pos, 1, 1);                                   // Always 1

    bits_to_10bytes(bits, out);

    ESP_LOGD(TAG, "HSI: int=%d hue=%d sat=%d cct=%dK sleep=%d -> %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
             intensity, hue, sat, cct_kelvin, sleep_mode,
             out[0], out[1], out[2], out[3], out[4],
             out[5], out[6], out[7], out[8], out[9]);
}

// ---------------------------------------------------------------------------
// Sleep Protocol (commandType = 12)
// ---------------------------------------------------------------------------

void sidus_build_sleep(bool on, uint8_t out[10])
{
    int sleep_mode = on ? 1 : 0;
    int command_type = 12;

    uint8_t bits[80];
    memset(bits, 0, sizeof(bits));
    int pos = 0;

    append_segment(bits, &pos, 0, 8);                                   // Reserved
    append_segment(bits, &pos, sleep_mode, 1);                          // Sleep mode
    append_segment(bits, &pos, 0, 20);                                  // Reserved
    append_segment(bits, &pos, 0, 12);                                  // Reserved
    append_segment(bits, &pos, 0, 1);                                   // autoPatchFlag
    append_segment(bits, &pos, 0, 1);                                   // CCT high flag
    append_segment(bits, &pos, 0, 1);                                   // GM flag
    append_segment(bits, &pos, 0, 1);                                   // GM high
    append_segment(bits, &pos, 0, 7);                                   // GM value
    append_segment(bits, &pos, 0, 10);                                  // CCT
    append_segment(bits, &pos, 0, 10);                                  // Intensity
    append_segment(bits, &pos, command_type, 7);                        // Command type = 12
    append_segment(bits, &pos, 1, 1);                                   // operaType = 1

    bits_to_10bytes(bits, out);

    ESP_LOGD(TAG, "Sleep: on=%d -> %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
             on,
             out[0], out[1], out[2], out[3], out[4],
             out[5], out[6], out[7], out[8], out[9]);
}

// ---------------------------------------------------------------------------
// Effect Protocol (commandType = 7)
// ---------------------------------------------------------------------------

void sidus_build_effect(int effect_type, double intensity_pct, int frq, int cct_kelvin,
                        int cop_car_color, int effect_mode, int hue, int saturation,
                        uint8_t out[10])
{
    int intensity = (int)round(intensity_pct * 10.0);
    intensity = clamp_int(intensity, 0, 1000);
    int cct = cct_kelvin / 10;
    cct = clamp_int(cct, 180, 2000);
    int sat = clamp_int(saturation, 0, 100);
    hue = clamp_int(hue, 0, 360);
    frq = clamp_int(frq, 0, 15);

    // Default effect params (matching Swift defaults)
    int sleep_mode = 1;
    int gm = 100;
    int gm_flag = 0;
    int color = clamp_int(cop_car_color, 0, 15);
    int speed = 8;
    int trigger = 2;
    int min_val = 0;
    int type_val = 0;    // Fireworks type

    uint8_t bits[80];
    memset(bits, 0, sizeof(bits));
    int pos = 0;

    int gm_high, gm_value;
    int cct_high;
    int cct_value;

    switch (effect_type) {

    // ----- TV (3), Candle (4), Fire (5) — simple with cct -----
    case 3:
    case 4:
    case 5:
        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, sleep_mode, 1);
        append_segment(bits, &pos, 0, 20);
        append_segment(bits, &pos, 0, 11);
        append_segment(bits, &pos, cct, 10);
        append_segment(bits, &pos, frq, 4);
        append_segment(bits, &pos, intensity, 10);
        append_segment(bits, &pos, effect_type, 8);
        append_segment(bits, &pos, 7, 7);
        append_segment(bits, &pos, 1, 1);
        break;

    // ----- Paparazzi (1) — cct + gm fields -----
    case 1:
        cct_high = (cct * 10 > 10000) ? 1 : 0;
        compute_gm(gm_flag, gm, &gm_high, &gm_value);
        cct_value = compute_cct_value(cct);

        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, sleep_mode, 1);
        append_segment(bits, &pos, 0, 20);
        append_segment(bits, &pos, 0, 1);
        append_segment(bits, &pos, cct_high, 1);
        append_segment(bits, &pos, gm_flag, 1);
        append_segment(bits, &pos, gm_high, 1);
        append_segment(bits, &pos, gm_value, 7);
        append_segment(bits, &pos, cct_value, 10);
        append_segment(bits, &pos, frq, 4);
        append_segment(bits, &pos, intensity, 10);
        append_segment(bits, &pos, effect_type, 8);
        append_segment(bits, &pos, 7, 7);
        append_segment(bits, &pos, 1, 1);
        break;

    // ----- Lightning (2) — cct + gm + speed + trigger -----
    case 2:
        cct_high = (cct * 10 > 10000) ? 1 : 0;
        compute_gm(gm_flag, gm, &gm_high, &gm_value);
        cct_value = compute_cct_value(cct);

        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, sleep_mode, 1);
        append_segment(bits, &pos, 0, 15);
        append_segment(bits, &pos, cct_high, 1);
        append_segment(bits, &pos, gm_flag, 1);
        append_segment(bits, &pos, gm_high, 1);
        append_segment(bits, &pos, speed, 4);
        append_segment(bits, &pos, trigger, 2);
        append_segment(bits, &pos, gm_value, 7);
        append_segment(bits, &pos, cct_value, 10);
        append_segment(bits, &pos, frq, 4);
        append_segment(bits, &pos, intensity, 10);
        append_segment(bits, &pos, effect_type, 8);
        append_segment(bits, &pos, 7, 7);
        append_segment(bits, &pos, 1, 1);
        break;

    // ----- CopCar (11) — color(4) -----
    case 11:
        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, sleep_mode, 1);
        append_segment(bits, &pos, 0, 20);
        append_segment(bits, &pos, 0, 17);
        append_segment(bits, &pos, color, 4);
        append_segment(bits, &pos, frq, 4);
        append_segment(bits, &pos, intensity, 10);
        append_segment(bits, &pos, effect_type, 8);
        append_segment(bits, &pos, 7, 7);
        append_segment(bits, &pos, 1, 1);
        break;

    // ----- Party (13) — sat(7) -----
    case 13:
        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, sleep_mode, 1);
        append_segment(bits, &pos, 0, 20);
        append_segment(bits, &pos, 0, 14);
        append_segment(bits, &pos, sat, 7);
        append_segment(bits, &pos, frq, 4);
        append_segment(bits, &pos, intensity, 10);
        append_segment(bits, &pos, effect_type, 8);
        append_segment(bits, &pos, 7, 7);
        append_segment(bits, &pos, 1, 1);
        break;

    // ----- Fireworks (14) — type(8) -----
    case 14:
        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, sleep_mode, 1);
        append_segment(bits, &pos, 0, 20);
        append_segment(bits, &pos, 0, 13);
        append_segment(bits, &pos, type_val, 8);
        append_segment(bits, &pos, frq, 4);
        append_segment(bits, &pos, intensity, 10);
        append_segment(bits, &pos, effect_type, 8);
        append_segment(bits, &pos, 7, 7);
        append_segment(bits, &pos, 1, 1);
        break;

    // ----- Strobe (6), Explosion (7) — multi-mode CCT or HSI -----
    case 6:
    case 7:
        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, sleep_mode, 1);

        cct_high = (cct * 10 > 10000) ? 1 : 0;
        compute_gm(gm_flag, gm, &gm_high, &gm_value);
        cct_value = compute_cct_value(cct);

        if (effect_mode == 1) {
            // HSI mode
            append_segment(bits, &pos, 0, 1);
            append_segment(bits, &pos, cct_high, 1);
            append_segment(bits, &pos, gm_flag, 1);
            append_segment(bits, &pos, gm_high, 1);
            append_segment(bits, &pos, trigger, 2);
            append_segment(bits, &pos, gm_value, 7);

            // CCT as 8-bit in HSI mode
            int cct_hsi = cct * 50;
            if (cct_hsi > 10000) cct_hsi -= 10000;
            cct_hsi = cct_hsi / 50;
            append_segment(bits, &pos, cct_hsi, 8);

            append_segment(bits, &pos, sat, 7);
            append_segment(bits, &pos, hue, 9);
        } else {
            // CCT mode
            append_segment(bits, &pos, 0, 15);
            append_segment(bits, &pos, cct_high, 1);
            append_segment(bits, &pos, gm_flag, 1);
            append_segment(bits, &pos, gm_high, 1);
            append_segment(bits, &pos, trigger, 2);
            append_segment(bits, &pos, gm_value, 7);
            append_segment(bits, &pos, cct_value, 10);
        }
        append_segment(bits, &pos, intensity, 10);
        append_segment(bits, &pos, frq, 4);
        append_segment(bits, &pos, effect_mode, 4);
        append_segment(bits, &pos, effect_type, 8);
        append_segment(bits, &pos, 7, 7);
        append_segment(bits, &pos, 1, 1);
        break;

    // ----- FaultyBulb (8), Pulsing (9) — multi-mode + speed -----
    case 8:
    case 9:
        cct_high = (cct * 10 > 10000) ? 1 : 0;
        compute_gm(gm_flag, gm, &gm_high, &gm_value);
        cct_value = compute_cct_value(cct);

        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, sleep_mode, 1);
        append_segment(bits, &pos, 0, 11);
        append_segment(bits, &pos, cct_high, 1);
        append_segment(bits, &pos, gm_flag, 1);
        append_segment(bits, &pos, gm_high, 1);
        append_segment(bits, &pos, speed, 4);
        append_segment(bits, &pos, trigger, 2);
        append_segment(bits, &pos, gm_value, 7);
        append_segment(bits, &pos, cct_value, 10);
        append_segment(bits, &pos, intensity, 10);
        append_segment(bits, &pos, frq, 4);
        append_segment(bits, &pos, effect_mode, 4);
        append_segment(bits, &pos, effect_type, 8);
        append_segment(bits, &pos, 7, 7);
        append_segment(bits, &pos, 1, 1);
        break;

    // ----- Welding (10) — multi-mode + min -----
    case 10:
        cct_high = (cct * 10 > 10000) ? 1 : 0;
        compute_gm(gm_flag, gm, &gm_high, &gm_value);
        cct_value = compute_cct_value(cct);

        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, sleep_mode, 1);
        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, cct_high, 1);
        append_segment(bits, &pos, gm_flag, 1);
        append_segment(bits, &pos, gm_high, 1);
        append_segment(bits, &pos, min_val, 7);
        append_segment(bits, &pos, trigger, 2);
        append_segment(bits, &pos, gm_value, 7);
        append_segment(bits, &pos, cct_value, 10);
        append_segment(bits, &pos, intensity, 10);
        append_segment(bits, &pos, frq, 4);
        append_segment(bits, &pos, effect_mode, 4);
        append_segment(bits, &pos, effect_type, 8);
        append_segment(bits, &pos, 7, 7);
        append_segment(bits, &pos, 1, 1);
        break;

    // ----- Effect Off (15) -----
    case 15:
        append_segment(bits, &pos, 0, 8);
        append_segment(bits, &pos, 0, 1);
        append_segment(bits, &pos, 0, 20);
        append_segment(bits, &pos, 0, 20);
        append_segment(bits, &pos, 0, 15);
        append_segment(bits, &pos, 15, 8);
        append_segment(bits, &pos, 7, 7);
        append_segment(bits, &pos, 1, 1);
        break;

    // ----- Unknown effect -> send effect off -----
    default:
        ESP_LOGD(TAG, "Unknown effect type %d, sending effect off", effect_type);
        sidus_build_effect(15, intensity_pct, frq, cct_kelvin,
                           cop_car_color, effect_mode, hue, saturation, out);
        return;
    }

    bits_to_10bytes(bits, out);

    ESP_LOGD(TAG, "Effect: type=%d int=%d frq=%d cct=%dK mode=%d -> "
             "%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
             effect_type, intensity, frq, cct_kelvin, effect_mode,
             out[0], out[1], out[2], out[3], out[4],
             out[5], out[6], out[7], out[8], out[9]);
}

// ---------------------------------------------------------------------------
// Access message builders: prepend 0x26 to make 11-byte messages
// ---------------------------------------------------------------------------

void sidus_build_access_cct(double intensity, int cct_kelvin, int sleep_mode, uint8_t out[11])
{
    out[0] = 0x26;
    sidus_build_cct(intensity, cct_kelvin, sleep_mode, &out[1]);
}

void sidus_build_access_hsi(double intensity, int hue, int saturation, int cct_kelvin, int sleep_mode, uint8_t out[11])
{
    out[0] = 0x26;
    sidus_build_hsi(intensity, hue, saturation, cct_kelvin, sleep_mode, &out[1]);
}

void sidus_build_access_sleep(bool on, uint8_t out[11])
{
    out[0] = 0x26;
    sidus_build_sleep(on, &out[1]);
}

void sidus_build_access_effect(int effect_type, double intensity, int frq, int cct_kelvin,
                               int cop_car_color, int effect_mode, int hue, int saturation,
                               uint8_t out[11])
{
    out[0] = 0x26;
    sidus_build_effect(effect_type, intensity, frq, cct_kelvin,
                       cop_car_color, effect_mode, hue, saturation, &out[1]);
}
