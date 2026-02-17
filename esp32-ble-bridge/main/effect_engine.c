/*
 * effect_engine.c — Software lighting effects engine for ESP32 BLE bridge.
 *
 * Port of FaultyBulbEngine, PaparazziEngine, and SoftwareEffectEngine from
 * BLEManager.swift.  Each effect runs as a chain of one-shot esp_timers that
 * re-arm themselves in their callbacks, allowing variable intervals per step.
 */

#include "effect_engine.h"
#include "ble_mesh.h"
#include "light_registry.h"

#include <math.h>
#include <string.h>
#include <stdlib.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "esp_random.h"
#include "cJSON.h"

static const char *TAG = "effect_engine";

/* -----------------------------------------------------------------------
 * Random helpers
 * ----------------------------------------------------------------------- */

/// Uniformly distributed double in [lo, hi].
static double rand_double(double lo, double hi)
{
    double t = (double)esp_random() / (double)UINT32_MAX;
    return lo + t * (hi - lo);
}

/// Uniformly distributed int in [lo, hi] (inclusive).
static int rand_int(int lo, int hi)
{
    if (lo >= hi) return lo;
    return lo + (int)(esp_random() % (uint32_t)(hi - lo + 1));
}

/* -----------------------------------------------------------------------
 * Instance pool
 * ----------------------------------------------------------------------- */

static effect_instance_t s_instances[MAX_LIGHTS];
static bool s_initialized = false;

/* -----------------------------------------------------------------------
 * Timer context — passed through one-shot timer callbacks
 *
 * We pack auxiliary data (fade targets, step counters, sweep parameters)
 * into this small heap-allocated struct.  It is freed by the callback.
 * ----------------------------------------------------------------------- */

typedef struct {
    effect_instance_t *inst;
    int tag;
    double d1, d2, d3;
    int i1, i2;
} timer_ctx_t;

/* Callback tag values */
enum {
    /* Faulty Bulb */
    CB_FAULTY_EVENT = 1,
    CB_FAULTY_FADE,
    /* Paparazzi */
    CB_PAPARAZZI_FLASH,
    CB_PAPARAZZI_OFF,
    CB_PAPARAZZI_BURST_ON,
    CB_PAPARAZZI_BURST_OFF,
    /* Software effects (generic) */
    CB_SOFTWARE_STEP,
    /* Software — strobe */
    CB_SOFTWARE_STROBE_OFF,
    CB_SOFTWARE_STROBE_NEXT,
    /* Software — lightning */
    CB_SOFTWARE_LIGHTNING_OFF,
    /* Software — explosion gap */
    CB_SOFTWARE_EXPLOSION_GAP,
    /* Software — welding */
    CB_SOFTWARE_WELD_OFF,
    CB_SOFTWARE_WELD_NEXT,
    /* Software — party sweep */
    CB_SOFTWARE_PARTY_SWEEP_START,
    CB_SOFTWARE_PARTY_SWEEP_STEP,
};

/* Forward-declare the dispatcher so arm_timer can reference it. */
static void timer_dispatch(void *arg);

/* -----------------------------------------------------------------------
 * arm_timer — create a one-shot esp_timer, deleting any previous one on
 *             the same instance.
 * ----------------------------------------------------------------------- */

static void arm_timer(effect_instance_t *inst, double delay_sec, int tag,
                      double d1, double d2, double d3, int i1, int i2)
{
    if (!inst->running) return;

    timer_ctx_t *ctx = calloc(1, sizeof(timer_ctx_t));
    if (!ctx) {
        ESP_LOGE(TAG, "arm_timer: alloc failed");
        return;
    }
    ctx->inst = inst;
    ctx->tag  = tag;
    ctx->d1   = d1;
    ctx->d2   = d2;
    ctx->d3   = d3;
    ctx->i1   = i1;
    ctx->i2   = i2;

    /* Delete the previous timer if present. */
    if (inst->timer) {
        esp_timer_stop((esp_timer_handle_t)inst->timer);
        esp_timer_delete((esp_timer_handle_t)inst->timer);
        inst->timer = NULL;
    }

    esp_timer_create_args_t args = {
        .callback        = timer_dispatch,
        .arg             = ctx,
        .dispatch_method = ESP_TIMER_TASK,
        .name            = "fx",
    };
    esp_timer_handle_t handle = NULL;
    esp_err_t err = esp_timer_create(&args, &handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_timer_create: %s", esp_err_to_name(err));
        free(ctx);
        return;
    }
    inst->timer = handle;

    int64_t us = (int64_t)(delay_sec * 1e6);
    if (us < 50) us = 50;
    err = esp_timer_start_once(handle, us);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_timer_start_once: %s", esp_err_to_name(err));
        esp_timer_delete(handle);
        inst->timer = NULL;
        free(ctx);
    }
}

static inline void arm_simple(effect_instance_t *inst, double delay_sec, int tag)
{
    arm_timer(inst, delay_sec, tag, 0, 0, 0, 0, 0);
}

/* -----------------------------------------------------------------------
 * Color-send helpers
 * ----------------------------------------------------------------------- */

static void send_cct(effect_instance_t *inst, double intensity, int cct, int sleep_mode)
{
    ble_mesh_send_cct(inst->unicast, intensity, cct, sleep_mode);
}

static void send_hsi(effect_instance_t *inst, double intensity, int hue,
                     int sat, int cct, int sleep_mode)
{
    ble_mesh_send_hsi(inst->unicast, intensity, hue, sat, cct, sleep_mode);
}

/// Send in the instance's configured color mode.
static void send_color(effect_instance_t *inst, double intensity, int sleep_mode)
{
    const effect_params_t *p = &inst->params;
    if (p->color_mode == COLOR_MODE_HSI)
        send_hsi(inst, intensity, p->hue, p->saturation, p->hsi_cct, sleep_mode);
    else
        send_cct(inst, intensity, p->cct_kelvin, sleep_mode);
}

/// Send with a hue override (for party mode).  If hue_override < 0, use default.
static void send_color_hue(effect_instance_t *inst, double intensity,
                           int sleep_mode, int hue_override)
{
    const effect_params_t *p = &inst->params;
    if (p->color_mode == COLOR_MODE_HSI || hue_override >= 0) {
        int h = (hue_override >= 0) ? hue_override : p->hue;
        send_hsi(inst, intensity, h, p->saturation, p->hsi_cct, sleep_mode);
    } else {
        send_cct(inst, intensity, p->cct_kelvin, sleep_mode);
    }
}

/* ===================================================================== *
 *  FAULTY BULB ENGINE                                                    *
 * ===================================================================== */

/* Send intensity with warmth-shifted CCT. */
static void faulty_send(effect_instance_t *inst, double percent, int sleep_mode)
{
    const effect_params_t *p = &inst->params;
    int adjusted_cct;

    if (p->faulty_warmth > 0 && p->faulty_max > p->faulty_min) {
        double dip = fmax(0, fmin(1, (p->faulty_max - percent) / (p->faulty_max - p->faulty_min)));
        double shift = dip * (p->faulty_warmth / 100.0);
        int base_cct = (p->color_mode == COLOR_MODE_HSI) ? p->hsi_cct : p->cct_kelvin;
        adjusted_cct = (int)(base_cct + (double)(p->faulty_warmest_cct - base_cct) * shift);
        ESP_LOGD(TAG, "FaultyBulb: i=%d%% dip=%.2f shift=%.2f base=%dK warm=%dK -> %dK",
                 (int)percent, dip, shift, base_cct, p->faulty_warmest_cct, adjusted_cct);
    } else {
        adjusted_cct = (p->color_mode == COLOR_MODE_HSI) ? p->hsi_cct : p->cct_kelvin;
    }

    if (p->color_mode == COLOR_MODE_HSI)
        send_hsi(inst, percent, p->hue, p->saturation, adjusted_cct, sleep_mode);
    else
        send_cct(inst, percent, adjusted_cct, sleep_mode);
}

/* Build discrete intensity levels from range and point count. */
static int faulty_points(const effect_params_t *p, double *out, int max_n)
{
    double lo = fmin(p->faulty_min, p->faulty_max);
    double hi = fmax(p->faulty_min, p->faulty_max);
    int n = p->faulty_points < 2 ? 2 : p->faulty_points;
    if (n > max_n) n = max_n;
    if (lo == hi) { out[0] = lo; return 1; }
    for (int i = 0; i < n; i++)
        out[i] = lo + (hi - lo) * (double)i / (double)(n - 1);
    return n;
}

/* Schedule the next faulty-bulb event. */
static void faulty_schedule(effect_instance_t *inst)
{
    if (!inst->running) return;
    int freq = (int)inst->params.faulty_frequency;
    double interval;
    if (freq >= 10) {
        interval = rand_double(0.08, 2.0);
    } else {
        double base = 1.5 * pow(0.65, (double)(freq - 1));
        interval = base * rand_double(0.85, 1.15);
    }
    arm_simple(inst, interval, CB_FAULTY_EVENT);
}

/* Fade step — called repeatedly via timer until steps exhausted. */
static void faulty_fade(effect_instance_t *inst, double target, int steps, double dt)
{
    if (!inst->running) return;
    if (steps <= 0) {
        inst->current_intensity = target;
        faulty_send(inst, target, 1);
        faulty_schedule(inst);
        return;
    }
    double interp = inst->current_intensity +
                    (target - inst->current_intensity) / (double)steps;
    inst->current_intensity = interp;
    faulty_send(inst, interp, 1);

    /* d1=target, d2=dt, i1=steps-1 */
    arm_timer(inst, dt, CB_FAULTY_FADE, target, dt, 0, steps - 1, 0);
}

/* Fire one flicker event. */
static void faulty_fire(effect_instance_t *inst)
{
    if (!inst->running) return;
    const effect_params_t *p = &inst->params;

    double pts[32];
    int npts = faulty_points(p, pts, 32);
    double hi = pts[npts - 1];

    double bias = pow(p->faulty_bias / 100.0, 2.5);
    if (bias <= 0) {
        if (fabs(inst->current_intensity - hi) > 0.5) {
            inst->current_intensity = hi;
            faulty_send(inst, hi, 1);
        }
        faulty_schedule(inst);
        return;
    }

    double target;
    bool on_high = fabs(inst->current_intensity - hi) < 0.5;

    /* Collect lower points for reuse. */
    double lower[32];
    int nlower = 0;
    for (int i = 0; i < npts; i++)
        if (pts[i] < hi - 0.5) lower[nlower++] = pts[i];

    if (on_high) {
        if (rand_double(0, 1) < bias) {
            target = (nlower > 0) ? lower[rand_int(0, nlower - 1)] : hi;
        } else {
            faulty_schedule(inst);
            return;
        }
    } else {
        double ret = 0.10 + 0.90 * pow(p->faulty_recovery / 100.0, 2.0);
        if (rand_double(0, 1) < ret) {
            target = hi;
        } else {
            target = (nlower > 0) ? lower[rand_int(0, nlower - 1)] : hi;
        }
    }

    double lo = fmin(p->faulty_min, p->faulty_max);

    if (p->faulty_transition < 0.005) {
        inst->current_intensity = target;
        if (target <= lo && lo < 1.0)
            faulty_send(inst, 0, 0);
        else
            faulty_send(inst, target, 1);
        faulty_schedule(inst);
    } else {
        double dt = 0.02;
        int total = (int)(p->faulty_transition / dt);
        if (total < 1) total = 1;
        faulty_fade(inst, target, total, dt);
    }
}

/* ===================================================================== *
 *  PAPARAZZI ENGINE                                                      *
 * ===================================================================== */

static void paparazzi_schedule(effect_instance_t *inst)
{
    if (!inst->running) return;
    double gap = 3.0 * pow(0.75, inst->params.frequency) * rand_double(0.5, 1.5);
    arm_simple(inst, gap, CB_PAPARAZZI_FLASH);
}

/* Fire the initial flash. */
static void paparazzi_flash(effect_instance_t *inst)
{
    if (!inst->running) return;
    double inten = fmax(inst->params.intensity, 10);
    send_color(inst, inten, 1);

    double flash_dur = rand_double(0.03, 0.08);
    /* d1 = flash_dur (so burst can reuse same range) */
    arm_timer(inst, flash_dur, CB_PAPARAZZI_OFF, flash_dur, 0, 0, 0, 0);
}

/* Flash OFF — optionally trigger double burst. */
static void paparazzi_off(effect_instance_t *inst, double flash_dur)
{
    if (!inst->running) return;
    send_color(inst, 0, 0);

    if (rand_double(0, 1) < 0.3) {
        /* Double burst */
        double burst_delay = rand_double(0.05, 0.15);
        arm_timer(inst, burst_delay, CB_PAPARAZZI_BURST_ON, flash_dur, 0, 0, 0, 0);
    } else {
        paparazzi_schedule(inst);
    }
}

/* Second burst ON. */
static void paparazzi_burst_on(effect_instance_t *inst, double flash_dur)
{
    if (!inst->running) return;
    double inten = fmax(inst->params.intensity, 10);
    send_color(inst, inten, 1);
    arm_timer(inst, flash_dur, CB_PAPARAZZI_BURST_OFF, 0, 0, 0, 0, 0);
}

/* Second burst OFF. */
static void paparazzi_burst_off(effect_instance_t *inst)
{
    if (!inst->running) return;
    send_color(inst, 0, 0);
    paparazzi_schedule(inst);
}

/* ===================================================================== *
 *  SOFTWARE EFFECT ENGINE                                                *
 * ===================================================================== */

static double biased_hue(effect_instance_t *inst, double hue)
{
    double h = hue + inst->params.party_hue_bias;
    h = fmod(h, 360.0);
    if (h < 0) h += 360.0;
    return h;
}

/* Forward declarations for mutually-recursive functions. */
static void sw_fire(effect_instance_t *inst);
static void sw_schedule(effect_instance_t *inst);
static void sw_strobe(effect_instance_t *inst);
static void sw_weld(effect_instance_t *inst, int remaining);

/* Schedule next software-effect step. */
static void sw_schedule(effect_instance_t *inst)
{
    if (!inst->running) return;
    const effect_params_t *p = &inst->params;
    double iv;

    switch (inst->type) {
    case EFFECT_CANDLE:
        iv = 0.15 * pow(0.85, p->frequency) * rand_double(0.7, 1.3);
        break;
    case EFFECT_FIRE:
        iv = 0.10 * pow(0.85, p->frequency) * rand_double(0.5, 1.5);
        break;
    case EFFECT_TV_FLICKER:
        iv = 0.08 * pow(0.85, p->frequency) * rand_double(0.6, 1.4);
        break;
    case EFFECT_LIGHTNING: {
        double bg = 3.0 * pow(0.75, p->frequency);
        iv = bg * rand_double(0.5, 1.5);
        break;
    }
    case EFFECT_PULSING:
        iv = 0.03;
        break;
    case EFFECT_EXPLOSION:
        iv = 0.04;
        break;
    case EFFECT_STROBE:
        iv = 0.5 / p->strobe_hz;
        break;
    case EFFECT_PARTY:
        iv = 1.5 * pow(0.80, p->frequency);
        break;
    case EFFECT_WELDING: {
        double bg = 1.5 * pow(0.80, p->frequency);
        iv = bg * rand_double(0.3, 1.0);
        break;
    }
    default:
        iv = 0.12 * pow(0.85, p->frequency) * rand_double(0.7, 1.3);
        break;
    }

    arm_simple(inst, iv, CB_SOFTWARE_STEP);
}

/* Sweep party hue one step at a time. */
static void sw_sweep_step(effect_instance_t *inst, double start_hue, double delta,
                          int step, int total_steps, double dt)
{
    if (!inst->running) return;
    if (step > total_steps) {
        sw_fire(inst);
        return;
    }
    double frac = (double)step / (double)total_steps;
    double hue = start_hue + delta * frac;
    if (hue < 0) hue += 360;
    if (hue >= 360) hue -= 360;
    send_color_hue(inst, inst->params.intensity, 1, (int)hue);

    /* d1=start_hue, d2=delta, d3=dt, i1=step+1, i2=total_steps */
    arm_timer(inst, dt, CB_SOFTWARE_PARTY_SWEEP_STEP,
              start_hue, delta, dt, step + 1, total_steps);
}

/* Start a hue sweep from start_hue to end_hue. */
static void sw_sweep_start(effect_instance_t *inst, double start_hue,
                           double end_hue, double duration)
{
    if (!inst->running) return;
    if (duration <= 0.03) { sw_fire(inst); return; }

    double dt = 0.03;
    int total = (int)(duration / dt);
    if (total < 1) total = 1;

    double delta = end_hue - start_hue;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;

    sw_sweep_step(inst, start_hue, delta, 1, total, dt);
}

/* Strobe flash cycle. */
static void sw_strobe(effect_instance_t *inst)
{
    if (!inst->running || !inst->strobe_running) return;
    double flash_ms = 0.010;
    double cycle = 1.0 / inst->params.strobe_hz;
    double off_dur = fmax(0.01, cycle - flash_ms);

    send_color(inst, inst->params.intensity, 1);
    inst->current_intensity = inst->params.intensity;

    /* d1 = off_dur */
    arm_timer(inst, flash_ms, CB_SOFTWARE_STROBE_OFF, off_dur, 0, 0, 0, 0);
}

/* Welding burst cycle. */
static void sw_weld(effect_instance_t *inst, int remaining)
{
    if (!inst->running || remaining <= 0) {
        send_color(inst, 0, 0);
        inst->current_intensity = 0;
        sw_schedule(inst);
        return;
    }
    double arc = inst->params.intensity * rand_double(0.7, 1.0);
    send_color(inst, arc, 1);

    double on_time = rand_double(0.02, 0.08);
    inst->weld_remaining = remaining;
    arm_simple(inst, on_time, CB_SOFTWARE_WELD_OFF);
}

/* Main step dispatcher for all software effects. */
static void sw_fire(effect_instance_t *inst)
{
    if (!inst->running) return;
    const effect_params_t *p = &inst->params;

    switch (inst->type) {

    case EFFECT_CANDLE: {
        double t = p->intensity * rand_double(0.60, 1.0);
        inst->current_intensity = t;
        send_color(inst, t, 1);
        sw_schedule(inst);
        break;
    }

    case EFFECT_FIRE: {
        bool burst = rand_double(0, 1) < 0.15;
        double t = burst ? p->intensity : p->intensity * rand_double(0.15, 0.85);
        inst->current_intensity = t;
        send_color(inst, t, 1);
        sw_schedule(inst);
        break;
    }

    case EFFECT_TV_FLICKER: {
        static const double levels[] = {0.1, 0.3, 0.5, 0.7, 0.85, 1.0};
        double t = p->intensity * levels[rand_int(0, 5)];
        inst->current_intensity = t;
        send_color(inst, t, 1);
        sw_schedule(inst);
        break;
    }

    case EFFECT_LIGHTNING: {
        send_color(inst, p->intensity, 1);
        double dur = rand_double(0.04, 0.12);
        arm_simple(inst, dur, CB_SOFTWARE_LIGHTNING_OFF);
        break;
    }

    case EFFECT_PULSING: {
        double lo = fmin(p->pulsing_min, p->pulsing_max);
        double hi = fmax(p->pulsing_min, p->pulsing_max);
        double period = 4.0 * pow(0.80, p->frequency);
        inst->phase_time += 0.03;
        double sine = (sin(inst->phase_time * 2.0 * M_PI / period) + 1.0) / 2.0;
        double norm = (p->pulsing_shape - 50.0) / 50.0;
        double exp_ = pow(10.0, -norm * 0.8);
        double shaped = pow(sine, exp_);
        double t = lo + (hi - lo) * shaped;
        inst->current_intensity = t;
        if (t < 1.0)
            send_color(inst, 0, 0);
        else
            send_color(inst, t, 1);
        sw_schedule(inst);
        break;
    }

    case EFFECT_EXPLOSION: {
        if (inst->current_intensity < 5.0 && inst->phase_time == 0) {
            /* Initial flash */
            inst->current_intensity = p->intensity;
            send_color(inst, p->intensity, 1);
            inst->phase_time = 1.0;
        } else if (inst->phase_time > 0) {
            inst->current_intensity *= 0.88;
            if (inst->current_intensity < 2.0) {
                send_color(inst, 0, 0);
                inst->current_intensity = 0;
                inst->phase_time = 0;
                double gap = 2.0 * pow(0.80, p->frequency) * rand_double(0.5, 1.5);
                arm_simple(inst, gap, CB_SOFTWARE_STEP);
                return;
            } else {
                send_color(inst, inst->current_intensity, 1);
            }
        } else {
            inst->phase_time = 0;
        }
        sw_schedule(inst);
        break;
    }

    case EFFECT_STROBE:
        sw_strobe(inst);
        return;

    case EFFECT_PARTY: {
        if (p->party_color_count <= 0) { sw_schedule(inst); break; }
        double cur_hue = biased_hue(inst, p->party_colors[inst->party_color_index]);
        int next_idx = (inst->party_color_index + 1) % p->party_color_count;
        inst->party_color_index = next_idx;
        send_color_hue(inst, p->intensity, 1, (int)cur_hue);

        if (p->party_transition <= 0 || p->party_color_count < 2) {
            sw_schedule(inst);
        } else {
            double total_iv = 1.5 * pow(0.80, p->frequency);
            double tfrac = p->party_transition / 100.0;
            double hold = total_iv * (1 - tfrac);
            double sweep = total_iv * tfrac;
            double next_hue = biased_hue(inst, p->party_colors[next_idx]);
            /* d1=cur_hue, d2=next_hue, d3=sweep */
            arm_timer(inst, hold, CB_SOFTWARE_PARTY_SWEEP_START,
                      cur_hue, next_hue, sweep, 0, 0);
        }
        break;
    }

    case EFFECT_WELDING: {
        int n = rand_int(2, 5);
        sw_weld(inst, n);
        break;
    }

    default: {
        double t = p->intensity * rand_double(0.3, 1.0);
        inst->current_intensity = t;
        send_color(inst, t, 1);
        sw_schedule(inst);
        break;
    }
    } /* switch */
}

/* -----------------------------------------------------------------------
 * Timer dispatch — the single callback for every one-shot timer.
 * ----------------------------------------------------------------------- */

static void timer_dispatch(void *arg)
{
    timer_ctx_t *ctx = (timer_ctx_t *)arg;
    effect_instance_t *inst = ctx->inst;

    if (!inst->running) {
        free(ctx);
        return;
    }

    /* Extract fields before freeing ctx. */
    int tag   = ctx->tag;
    double d1 = ctx->d1;
    double d2 = ctx->d2;
    double d3 = ctx->d3;
    int i1    = ctx->i1;
    int i2    = ctx->i2;
    free(ctx);

    switch (tag) {

    /* ---- Faulty Bulb ---- */
    case CB_FAULTY_EVENT:
        faulty_fire(inst);
        break;

    case CB_FAULTY_FADE:
        /* d1=target, d2=dt, i1=steps_remaining */
        faulty_fade(inst, d1, i1, d2);
        break;

    /* ---- Paparazzi ---- */
    case CB_PAPARAZZI_FLASH:
        paparazzi_flash(inst);
        break;

    case CB_PAPARAZZI_OFF:
        /* d1=flash_dur */
        paparazzi_off(inst, d1);
        break;

    case CB_PAPARAZZI_BURST_ON:
        /* d1=flash_dur */
        paparazzi_burst_on(inst, d1);
        break;

    case CB_PAPARAZZI_BURST_OFF:
        paparazzi_burst_off(inst);
        break;

    /* ---- Software effects ---- */
    case CB_SOFTWARE_STEP:
        sw_fire(inst);
        break;

    case CB_SOFTWARE_STROBE_OFF:
        /* d1=off_dur */
        if (!inst->strobe_running) break;
        send_color(inst, 0, 0);
        inst->current_intensity = 0;
        arm_simple(inst, d1, CB_SOFTWARE_STROBE_NEXT);
        break;

    case CB_SOFTWARE_STROBE_NEXT:
        sw_strobe(inst);
        break;

    case CB_SOFTWARE_LIGHTNING_OFF:
        send_color(inst, 0, 0);
        inst->current_intensity = 0;
        sw_schedule(inst);
        break;

    case CB_SOFTWARE_EXPLOSION_GAP:
        sw_fire(inst);
        break;

    case CB_SOFTWARE_WELD_OFF:
        /* Arc OFF, then brief gap before next burst */
        send_color(inst, 0, 0);
        {
            double off_time = rand_double(0.01, 0.04);
            int remaining = inst->weld_remaining - 1;
            inst->weld_remaining = remaining;
            arm_timer(inst, off_time, CB_SOFTWARE_WELD_NEXT, 0, 0, 0, remaining, 0);
        }
        break;

    case CB_SOFTWARE_WELD_NEXT:
        /* i1=remaining */
        sw_weld(inst, i1);
        break;

    case CB_SOFTWARE_PARTY_SWEEP_START:
        /* d1=start_hue, d2=end_hue, d3=sweep_duration */
        sw_sweep_start(inst, d1, d2, d3);
        break;

    case CB_SOFTWARE_PARTY_SWEEP_STEP:
        /* d1=start_hue, d2=delta, d3=dt, i1=step, i2=total_steps */
        sw_sweep_step(inst, d1, d2, i1, i2, d3);
        break;

    default:
        ESP_LOGW(TAG, "timer_dispatch: unknown tag %d", tag);
        break;
    }
}

/* ===================================================================== *
 *  PUBLIC API                                                            *
 * ===================================================================== */

void effect_engine_init(void)
{
    if (s_initialized) return;
    memset(s_instances, 0, sizeof(s_instances));
    s_initialized = true;
    ESP_LOGI(TAG, "effect engine initialized (max %d lights)", MAX_LIGHTS);
}

effect_instance_t *effect_engine_start(uint16_t unicast, effect_type_t type,
                                       const effect_params_t *params)
{
    if (!s_initialized) effect_engine_init();

    /* Stop any existing effect on this light. */
    effect_engine_stop(unicast);

    /* Find a free slot. */
    effect_instance_t *inst = NULL;
    for (int i = 0; i < MAX_LIGHTS; i++) {
        if (!s_instances[i].running) {
            inst = &s_instances[i];
            break;
        }
    }
    if (!inst) {
        ESP_LOGW(TAG, "no free effect slots");
        return NULL;
    }

    memset(inst, 0, sizeof(*inst));
    inst->unicast = unicast;
    inst->type    = type;
    if (params) inst->params = *params;
    inst->current_intensity = inst->params.intensity;
    inst->phase_time = 0;
    inst->running = true;

    /* Link to light registry. */
    light_entry_t *light = light_registry_find_by_unicast(unicast);
    if (light) light->active_effect = inst;

    ESP_LOGI(TAG, "start effect %d on 0x%04x", type, unicast);

    /* Kick off the first step. */
    switch (type) {
    case EFFECT_FAULTY_BULB:
        faulty_fire(inst);
        break;
    case EFFECT_PAPARAZZI:
        paparazzi_schedule(inst);
        break;
    case EFFECT_STROBE:
        /* Strobe starts dark, then begins flash loop. */
        send_color(inst, 0, 0);
        inst->strobe_running = true;
        arm_simple(inst, 0.05, CB_SOFTWARE_STROBE_NEXT);
        break;
    default:
        /* All other software effects */
        sw_fire(inst);
        break;
    }

    return inst;
}

void effect_engine_update(uint16_t unicast, const effect_params_t *params)
{
    if (!params) return;
    for (int i = 0; i < MAX_LIGHTS; i++) {
        if (s_instances[i].running && s_instances[i].unicast == unicast) {
            /* Preserve runtime state, only update parameters. */
            s_instances[i].params = *params;

            /* If party colors changed, clamp index. */
            if (s_instances[i].party_color_index >= params->party_color_count &&
                params->party_color_count > 0) {
                s_instances[i].party_color_index = 0;
            }

            ESP_LOGD(TAG, "updated params for 0x%04x", unicast);
            return;
        }
    }
}

void effect_engine_stop(uint16_t unicast)
{
    for (int i = 0; i < MAX_LIGHTS; i++) {
        effect_instance_t *inst = &s_instances[i];
        if (inst->running && inst->unicast == unicast) {
            inst->running = false;
            inst->strobe_running = false;

            if (inst->timer) {
                esp_timer_stop((esp_timer_handle_t)inst->timer);
                esp_timer_delete((esp_timer_handle_t)inst->timer);
                inst->timer = NULL;
            }

            /* Unlink from light registry. */
            light_entry_t *light = light_registry_find_by_unicast(unicast);
            if (light) light->active_effect = NULL;

            ESP_LOGI(TAG, "stopped effect on 0x%04x", unicast);
            return;
        }
    }
}

void effect_engine_stop_all(void)
{
    for (int i = 0; i < MAX_LIGHTS; i++) {
        if (s_instances[i].running) {
            effect_engine_stop(s_instances[i].unicast);
        }
    }
    ESP_LOGI(TAG, "all effects stopped");
}

/* ===================================================================== *
 *  JSON PARAMETER PARSING                                                *
 * ===================================================================== */

/// Helper: read a double field, returning fallback if missing.
static double json_double(const cJSON *obj, const char *key, double fallback)
{
    const cJSON *item = cJSON_GetObjectItem(obj, key);
    if (!item || !cJSON_IsNumber(item)) return fallback;
    return item->valuedouble;
}

/// Helper: read an int field, returning fallback if missing.
static int json_int(const cJSON *obj, const char *key, int fallback)
{
    const cJSON *item = cJSON_GetObjectItem(obj, key);
    if (!item || !cJSON_IsNumber(item)) return fallback;
    return item->valueint;
}

/// Helper: read a string field, returning fallback if missing.
static const char *json_str(const cJSON *obj, const char *key, const char *fallback)
{
    const cJSON *item = cJSON_GetObjectItem(obj, key);
    if (!item || !cJSON_IsString(item)) return fallback;
    return item->valuestring;
}

void effect_params_from_json(effect_params_t *params, const char *engine_name,
                              const void *json_params)
{
    if (!params || !json_params) return;
    const cJSON *obj = (const cJSON *)json_params;

    /* Common fields */
    const char *mode_str = json_str(obj, "colorMode", "cct");
    if (strcmp(mode_str, "hsi") == 0)
        params->color_mode = COLOR_MODE_HSI;
    else
        params->color_mode = COLOR_MODE_CCT;

    params->intensity   = json_double(obj, "intensity", 100.0);
    params->cct_kelvin  = json_int(obj, "cctKelvin", 5600);
    params->hue         = json_int(obj, "hue", 0);
    params->saturation  = json_int(obj, "saturation", 100);
    params->hsi_cct     = json_int(obj, "hsiCCT", 5600);
    params->frequency   = json_double(obj, "frequency", 8.0);

    /* Pulsing */
    params->pulsing_min   = json_double(obj, "pulsingMin", 0.0);
    params->pulsing_max   = json_double(obj, "pulsingMax", 100.0);
    params->pulsing_shape = json_double(obj, "pulsingShape", 50.0);

    /* Strobe */
    params->strobe_hz = json_double(obj, "strobeHz", 4.0);

    /* Faulty Bulb */
    if (engine_name && strcmp(engine_name, "faultyBulb") == 0) {
        params->faulty_min         = json_double(obj, "faultyMin", 20.0);
        params->faulty_max         = json_double(obj, "faultyMax", 100.0);
        params->faulty_bias        = json_double(obj, "faultyBias", 100.0);
        params->faulty_recovery    = json_double(obj, "faultyRecovery", 100.0);
        params->faulty_warmth      = json_double(obj, "faultyWarmth", 0.0);
        params->faulty_warmest_cct = json_int(obj, "warmestCCT", 2700);
        params->faulty_points      = json_int(obj, "faultyPoints", 2);
        params->faulty_transition  = json_double(obj, "faultyTransition", 0.0);
        params->faulty_frequency   = json_double(obj, "faultyFrequency", 5.0);
    }

    /* Party */
    params->party_transition = json_double(obj, "partyTransition", 0.0);
    params->party_hue_bias   = json_double(obj, "partyHueBias", 0.0);

    const cJSON *colors = cJSON_GetObjectItem(obj, "partyColors");
    if (colors && cJSON_IsArray(colors)) {
        int n = cJSON_GetArraySize(colors);
        if (n > 32) n = 32;
        params->party_color_count = n;
        for (int i = 0; i < n; i++) {
            const cJSON *c = cJSON_GetArrayItem(colors, i);
            params->party_colors[i] = cJSON_IsNumber(c) ? c->valuedouble : 0;
        }
    } else {
        /* Default rainbow if not specified */
        if (params->party_color_count == 0) {
            static const double default_colors[] = {0, 60, 120, 180, 240, 300};
            params->party_color_count = 6;
            memcpy(params->party_colors, default_colors, sizeof(default_colors));
        }
    }
}
