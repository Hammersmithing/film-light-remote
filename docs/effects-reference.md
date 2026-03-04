# Effects Engine Reference

Each software effect engine lives in its own isolated file under `FilmLightRemote/Sources/Effects/`. The UI for each effect is in `FilmLightRemote/Sources/Views/LightControlView.swift`.

Cue/timeline code is similarly isolated in `FilmLightRemote/Sources/Cues/`, and group code in `FilmLightRemote/Sources/Groups/`. See CLAUDE.md for the full listing.

---

## FaultyBulbEngine (`FaultyBulbEngine.swift`) - LOCKED

**Purpose:** Simulates a realistic flickering/faulty incandescent bulb by sending random intensity values within a configurable range at irregular intervals via BLE.

**Architecture:**
- Self-contained class with its own `DispatchQueue` (`com.filmlightremote.faultybulb`, `.userInitiated`)
- Stores copies of all parameters internally so it keeps running even after the view is dismissed
- Runs a self-scheduling event loop: `fireEvent()` -> `scheduleNextEvent()` -> `fireEvent()` ...
- Sends intensity via `setCCTWithSleep` or `setHSIWithSleep` depending on color mode

**Parameters (stored from LightState):**

| Parameter | LightState property | Range | Description |
|-----------|-------------------|-------|-------------|
| Color Mode | `faultyBulbColorMode` | `.cct` / `.hsi` | CCT or HSI color space |
| CCT | `cctKelvin` | 2700-6500 | Base color temperature |
| Hue | `hue` | 0-360 | HSI hue |
| Saturation | `saturation` | 0-100 | HSI saturation |
| Flicker Min | `faultyBulbMin` | 0-100 | Low end of flicker range |
| Flicker Max | `faultyBulbMax` | 0-100 | High end of flicker range |
| Fault Bias | `faultyBulbBias` | 0-100 | Probability of dipping (log-scaled: `pow(value/100, 2.5)`) |
| Recovery | `faultyBulbRecovery` | 0-100 | How quickly bulb returns to high after a dip |
| Warmth | `faultyBulbWarmth` | 0-100 | CCT shifts warmer during dips (incandescent thermal sim) |
| Warmest CCT | `warmestCCT` | from light | Warmest CCT the light supports (lower bound of CCT range) |
| Points | `faultyBulbPoints` | 2+ | Number of discrete intensity levels within range |
| Transition | `faultyBulbTransition` | 0-1.0 | Fade duration between levels (0 = instant snap) |
| Frequency | `faultyBulbFrequency` | 1-10 | Speed (1=slow ~1.5s, 9=fast ~0.08s, 10=Random 0.08-2.0s) |

**Algorithm Detail:**

1. **Discrete Points:** Builds `n` evenly-spaced intensity levels between min and max
2. **Fault Decision (on high point):** Uses log-scaled bias to determine dip probability. `bias=0` means never dips. `bias=100` means always dips.
3. **Recovery Decision (on low point):** `returnChance = 0.10 + 0.90 * pow(recovery/100, 2.0)`. Recovery=0 means elongated dips, Recovery=100 means instant return.
4. **Warmth Shift:** When warmth > 0, CCT shifts linearly from base CCT (at max intensity) toward warmest CCT (at min intensity), proportional to dip depth. Simulates incandescent thermal behavior.
5. **Transition:** If transition > 0, fades to target over that duration using 20ms steps. If transition = 0, uses sleep-mode toggling for instant hard cuts.
6. **Frequency Curve:** Exponential: `1.5 * pow(0.65, freq-1)` with +/-15% randomization. Position 10 = fully random interval.

**UI:** `FaultyBulbDetail` struct in LightControlView.swift
- `syncEngineParams()` pushes slider changes directly to running engine via `bleManager.faultyBulbEngine?.updateParams(from: lightState)`
- `sendColorNow()` sends immediate color preview + updates engine params

---

## PaparazziEngine (`PaparazziEngine.swift`)

**Purpose:** Simulates camera flash bursts with brief intense flashes at random intervals, with 30% chance of double flash bursts.

**Architecture:**
- Self-contained class, own `DispatchQueue` (`com.filmlightremote.paparazzi`)
- Loop: `scheduleNextFlash()` -> `fireFlash()` -> `scheduleNextFlash()` ...

**Parameters:**

| Parameter | LightState property | Description |
|-----------|-------------------|-------------|
| Color Mode | `paparazziColorMode` | CCT or HSI |
| Intensity | `intensity` | Flash brightness (min 10%) |
| Frequency | `effectFrequency` | Gap between flashes: `3.0 * pow(0.75, freq)` |

**Algorithm:**
1. Flash ON at full intensity for 30-80ms
2. Flash OFF
3. 30% chance: double flash burst (second flash after 50-150ms gap)
4. Wait for frequency-determined gap
5. Repeat

---

## SoftwareEffectEngine (`SoftwareEffectEngine.swift`)

**Purpose:** Generic engine handling multiple effect types, each with its own intensity/timing pattern.

**Architecture:**
- Self-contained class, own `DispatchQueue` (`com.filmlightremote.softwareeffect`)
- Loop: `fireStep()` -> `scheduleNext()` -> `fireStep()` ...
- Strobe has its own sub-loop: `strobeFlash()` (10ms pop flash)

**Supported Effects:**

| Effect | Pattern | Timing |
|--------|---------|--------|
| Candle | Gentle flicker 60-100% | `0.15 * pow(0.85, freq)` |
| Fire | Aggressive 15-100% + 15% bright bursts | `0.10 * pow(0.85, freq)` |
| TV Flicker | Random discrete levels [10,30,50,70,85,100%] | `0.08 * pow(0.85, freq)` |
| Lightning | Brief bright flash then off | `3.0 * pow(0.75, freq)` gap |
| Pulsing | Shaped sine wave between min/max, shape slider skews waveform | Fixed 30ms steps |
| Explosion | Flash then exponential decay (0.88x per step) | 40ms steps + gap between |
| Strobe | 10ms pop flash at configurable Hz (1-12) | `1/Hz` cycle period |
| Party | Cycles through user-defined hue list with optional sweep transitions | `1.5 * pow(0.80, freq)` |
| Welding | 2-5 rapid arc bursts (20-80ms on, 10-40ms off) then pause | `1.5 * pow(0.80, freq)` |

**Special Parameters:**
- Pulsing: `pulsingMin`, `pulsingMax`, `pulsingShape` (waveform skew: 0=bottom-heavy, 50=sine, 100=top-heavy)
- Strobe: `strobeHz` (1-12 Hz), 10ms pop flash duration
- Party: `partyColors` (hue array), `partyTransition` (0-100% sweep), `partyHueBias` (hue offset)

---

## Engine Lifecycle

**Start:** `bleManager.startFaultyBulb(lightState:)` / `startPaparazzi(lightState:)` / `startSoftwareEffect(lightState:)`
- Creates engine instance, appends to engine array, calls `engine.start(...)`

**Update:** View calls `engine.updateParams(from: lightState)` directly for live slider changes

**Stop:** `bleManager.stopFaultyBulb()` / `stopPaparazzi()` / `stopSoftwareEffect()`
- Iterates engine array, calls `engine.stop()`, removes from array

**Cleanup:** On peripheral disconnect, all engines targeting that peripheral are stopped and removed

**Storage:** `bleManager.faultyBulbEngines: [FaultyBulbEngine]`, `.paparazziEngines`, `.softwareEffectEngines` (arrays support multi-light operation)
