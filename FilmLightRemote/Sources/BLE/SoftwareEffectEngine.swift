import Foundation

// MARK: - Generic Software Effect Engine
/// Simulates lighting effects in HSI mode for lights that don't support native HSI effects.
/// Each effect type has its own intensity pattern, sent via setHSIWithSleep/setCCTWithSleep.
class SoftwareEffectEngine {
    private var workItem: DispatchWorkItem?
    private var bleManager: BLEManager?
    private let queue = DispatchQueue(label: "com.filmlightremote.softwareeffect", qos: .userInitiated)

    private(set) var targetAddress: UInt16 = 0x0002
    /// The peripheral this engine writes through (set at start time).
    private(set) var peripheralIdentifier: UUID = UUID()
    private var effectType: LightEffect = .none
    private var colorMode: LightMode = .hsi
    private var cctKelvin: Int = 5600
    private var hue: Int = 0
    private var saturation: Int = 100
    private var hsiCCT: Int = 5600
    private var intensity: Double = 100.0
    private var frequency: Double = 8.0
    private var pulsingMin: Double = 0.0
    private var pulsingMax: Double = 100.0
    private var pulsingShape: Double = 50.0
    private var strobeHz: Double = 4.0
    private var currentIntensity: Double = 0.0
    private var phaseTime: Double = 0.0 // for pulsing sine wave
    private var partyColors: [Double] = [0, 60, 120, 180, 240, 300]
    private var partyColorIndex: Int = 0
    private var partyTransition: Double = 0.0
    private var partyHueBias: Double = 0.0

    func start(bleManager: BLEManager, lightState: LightState, targetAddress: UInt16, peripheralIdentifier: UUID? = nil) {
        stop()
        self.bleManager = bleManager
        self.targetAddress = targetAddress
        self.peripheralIdentifier = peripheralIdentifier ?? bleManager.connectedPeripheral?.identifier ?? UUID()
        updateParams(from: lightState)
        currentIntensity = intensity
        phaseTime = 0
        // For strobe: start dark, then begin flash loop
        if effectType == .strobe {
            sendColor(intensity: 0, sleepMode: 0)
            strobeRunning = true
            queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.strobeFlash()
            }
            return
        }
        fireStep()
    }

    func stop() {
        strobeRunning = false
        workItem?.cancel()
        workItem = nil
        bleManager = nil
    }

    func updateParams(from lightState: LightState) {
        effectType = lightState.selectedEffect
        switch effectType {
        case .strobe: colorMode = lightState.strobeColorMode
        default: colorMode = lightState.effectColorMode
        }
        cctKelvin = Int(lightState.cctKelvin)
        hue = Int(lightState.hue)
        saturation = Int(lightState.saturation)
        hsiCCT = Int(lightState.hsiCCT)
        intensity = lightState.intensity
        frequency = lightState.effectFrequency
        pulsingMin = lightState.pulsingMin
        pulsingMax = lightState.pulsingMax
        pulsingShape = lightState.pulsingShape
        strobeHz = lightState.strobeHz
        if !lightState.partyColors.isEmpty {
            partyColors = lightState.partyColors
            // Reset index if it's out of bounds after colors were removed
            if partyColorIndex >= partyColors.count {
                partyColorIndex = 0
            }
        }
        partyTransition = lightState.partyTransition
        partyHueBias = lightState.partyHueBias
    }

    private func scheduleNext() {
        guard bleManager != nil else { return }

        let interval: Double
        switch effectType {
        case .candle:
            // Gentle flicker: slow base, frequency speeds it up
            interval = 0.15 * pow(0.85, frequency) * Double.random(in: 0.7...1.3)
        case .fire:
            // Aggressive flicker: faster
            interval = 0.10 * pow(0.85, frequency) * Double.random(in: 0.5...1.5)
        case .tvFlicker:
            // Random jumps at moderate speed
            interval = 0.08 * pow(0.85, frequency) * Double.random(in: 0.6...1.4)
        case .lightning:
            // Long pauses between flashes
            let baseGap = 3.0 * pow(0.75, frequency)
            interval = baseGap * Double.random(in: 0.5...1.5)
        case .pulsing:
            // Smooth sine: fixed step rate
            interval = 0.03
        case .explosion:
            // Fast decay steps
            interval = 0.04
        case .strobe:
            // Strobe: full cycle = 1/Hz, this is the OFF half
            interval = 0.5 / strobeHz
        case .party:
            // Color cycling: frequency controls speed
            interval = 1.5 * pow(0.80, frequency)
        case .welding:
            // Bursts with pauses
            let baseGap = 1.5 * pow(0.80, frequency)
            interval = baseGap * Double.random(in: 0.3...1.0)
        default:
            interval = 0.12 * pow(0.85, frequency) * Double.random(in: 0.7...1.3)
        }

        let work = DispatchWorkItem { [weak self] in
            self?.fireStep()
        }
        workItem = work
        queue.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func fireStep() {
        guard bleManager != nil else { return }

        switch effectType {
        case .candle:
            // Gentle flicker: 60-100% of base intensity
            let target = intensity * Double.random(in: 0.60...1.0)
            currentIntensity = target
            sendColor(intensity: target, sleepMode: 1)
            scheduleNext()

        case .fire:
            // Aggressive flicker: 15-100% with occasional bright bursts
            let burst = Double.random(in: 0...1) < 0.15
            let target = burst ? intensity : intensity * Double.random(in: 0.15...0.85)
            currentIntensity = target
            sendColor(intensity: target, sleepMode: 1)
            scheduleNext()

        case .tvFlicker:
            // Discrete random jumps between levels
            let levels: [Double] = [0.1, 0.3, 0.5, 0.7, 0.85, 1.0]
            let target = intensity * (levels.randomElement() ?? 0.5)
            currentIntensity = target
            sendColor(intensity: target, sleepMode: 1)
            scheduleNext()

        case .lightning:
            // Brief bright flash then off (like paparazzi but single flash)
            sendColor(intensity: intensity, sleepMode: 1)
            let flashDuration = Double.random(in: 0.04...0.12)
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.sendColor(intensity: 0, sleepMode: 0)
                self.currentIntensity = 0
                self.scheduleNext()
            }
            workItem = work
            queue.asyncAfter(deadline: .now() + flashDuration, execute: work)

        case .pulsing:
            // Smooth shaped wave between pulsingMin and pulsingMax
            let lo = min(pulsingMin, pulsingMax)
            let hi = max(pulsingMin, pulsingMax)
            let period = 4.0 * pow(0.80, frequency) // faster at higher freq
            phaseTime += 0.03
            let sine = (sin(phaseTime * 2.0 * .pi / period) + 1.0) / 2.0 // 0-1
            // Shape: 0=bottom-heavy, 50=sine, 100=top-heavy
            // Logarithmic exponent: 50→1.0, 0→~10, 100→~0.1
            let normalized = (pulsingShape - 50.0) / 50.0 // -1 to 1
            let exponent = pow(10.0, -normalized * 0.8) // 0→~6.3, 50→1, 100→~0.16
            let shaped = pow(sine, exponent)
            let target = lo + (hi - lo) * shaped
            currentIntensity = target
            if target < 1.0 {
                sendColor(intensity: 0, sleepMode: 0)
            } else {
                sendColor(intensity: target, sleepMode: 1)
            }
            scheduleNext()

        case .explosion:
            // Flash then exponential decay
            if currentIntensity < 5.0 && phaseTime == 0 {
                // Initial flash
                currentIntensity = intensity
                sendColor(intensity: intensity, sleepMode: 1)
                phaseTime = 1.0
            } else if phaseTime > 0 {
                // Decay
                currentIntensity *= 0.88
                if currentIntensity < 2.0 {
                    sendColor(intensity: 0, sleepMode: 0)
                    currentIntensity = 0
                    phaseTime = 0
                    // Wait before next explosion
                    let gap = 2.0 * pow(0.80, frequency) * Double.random(in: 0.5...1.5)
                    let work = DispatchWorkItem { [weak self] in
                        self?.fireStep()
                    }
                    workItem = work
                    queue.asyncAfter(deadline: .now() + gap, execute: work)
                    return
                } else {
                    sendColor(intensity: currentIntensity, sleepMode: 1)
                }
            } else {
                // Trigger new explosion
                phaseTime = 0
            }
            scheduleNext()

        case .strobe:
            strobeFlash()
            return

        case .party:
            // Cycle through user-defined hue list
            guard !partyColors.isEmpty else { scheduleNext(); return }
            let currentHue = biasedHue(partyColors[partyColorIndex])
            let nextIndex = (partyColorIndex + 1) % partyColors.count
            partyColorIndex = nextIndex
            sendColor(intensity: intensity, sleepMode: 1, hueOverride: Int(currentHue))

            if partyTransition <= 0 || partyColors.count < 2 {
                scheduleNext()
            } else {
                // Split interval into hold + sweep
                let totalInterval = 1.5 * pow(0.80, frequency)
                let transitionFrac = partyTransition / 100.0
                let holdTime = totalInterval * (1 - transitionFrac)
                let sweepTime = totalInterval * transitionFrac
                let nextHue = biasedHue(partyColors[nextIndex])

                let holdWork = DispatchWorkItem { [weak self] in
                    self?.sweepPartyHue(from: currentHue, to: nextHue, duration: sweepTime)
                }
                workItem = holdWork
                queue.asyncAfter(deadline: .now() + holdTime, execute: holdWork)
            }

        case .welding:
            // Bright arc burst then off
            let burstCount = Int.random(in: 2...5)
            weldBurst(remaining: burstCount)

        default:
            // Generic flicker fallback
            let target = intensity * Double.random(in: 0.3...1.0)
            currentIntensity = target
            sendColor(intensity: target, sleepMode: 1)
            scheduleNext()
        }
    }

    private var strobeRunning = false

    private func strobeFlash() {
        guard bleManager != nil, strobeRunning else { return }
        let flashDuration = 0.010 // 10ms pop
        let cyclePeriod = 1.0 / strobeHz
        let offDuration = max(0.01, cyclePeriod - flashDuration)

        // ON — full intensity
        sendColor(intensity: intensity, sleepMode: 1)
        currentIntensity = intensity

        // Schedule OFF after flash duration
        queue.asyncAfter(deadline: .now() + flashDuration) { [weak self] in
            guard let self = self, self.strobeRunning, self.bleManager != nil else { return }
            // OFF — zero intensity
            self.sendColor(intensity: 0, sleepMode: 0)
            self.currentIntensity = 0

            // Schedule next flash after off duration
            self.queue.asyncAfter(deadline: .now() + offDuration) { [weak self] in
                self?.strobeFlash()
            }
        }
    }

    private func weldBurst(remaining: Int) {
        guard bleManager != nil, remaining > 0 else {
            sendColor(intensity: 0, sleepMode: 0)
            currentIntensity = 0
            scheduleNext()
            return
        }
        // Arc ON
        let arcIntensity = intensity * Double.random(in: 0.7...1.0)
        sendColor(intensity: arcIntensity, sleepMode: 1)
        let onTime = Double.random(in: 0.02...0.08)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Brief off between arcs
            self.sendColor(intensity: 0, sleepMode: 0)
            let offTime = Double.random(in: 0.01...0.04)
            let next = DispatchWorkItem { [weak self] in
                self?.weldBurst(remaining: remaining - 1)
            }
            self.workItem = next
            self.queue.asyncAfter(deadline: .now() + offTime, execute: next)
        }
        workItem = work
        queue.asyncAfter(deadline: .now() + onTime, execute: work)
    }

    /// Apply hue bias, wrapping into 0-360
    private func biasedHue(_ hue: Double) -> Double {
        var h = hue + partyHueBias
        h = h.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return h
    }

    /// Sweep hue from startHue to endHue over duration, taking the shortest path around the wheel
    private func sweepPartyHue(from startHue: Double, to endHue: Double, duration: Double) {
        guard bleManager != nil else { return }
        guard duration > 0.03 else {
            // Too short to sweep, jump straight to next fireStep
            fireStep()
            return
        }

        let stepInterval: Double = 0.03
        let totalSteps = max(1, Int(duration / stepInterval))

        // Shortest path around hue wheel
        var delta = endHue - startHue
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        sweepPartyStep(startHue: startHue, delta: delta, step: 1, totalSteps: totalSteps, stepInterval: stepInterval)
    }

    private func sweepPartyStep(startHue: Double, delta: Double, step: Int, totalSteps: Int, stepInterval: Double) {
        guard bleManager != nil else { return }
        guard step <= totalSteps else {
            fireStep()
            return
        }

        let fraction = Double(step) / Double(totalSteps)
        var hue = startHue + delta * fraction
        if hue < 0 { hue += 360 }
        if hue >= 360 { hue -= 360 }

        sendColor(intensity: intensity, sleepMode: 1, hueOverride: Int(hue))

        let work = DispatchWorkItem { [weak self] in
            self?.sweepPartyStep(startHue: startHue, delta: delta, step: step + 1, totalSteps: totalSteps, stepInterval: stepInterval)
        }
        workItem = work
        queue.asyncAfter(deadline: .now() + stepInterval, execute: work)
    }

    private func sendColor(intensity: Double, sleepMode: Int, hueOverride: Int? = nil) {
        guard let mgr = bleManager else { return }
        if colorMode == .hsi || hueOverride != nil {
            mgr.setHSIWithSleep(
                intensity: intensity,
                hue: hueOverride ?? hue,
                saturation: saturation,
                cctKelvin: hsiCCT,
                sleepMode: sleepMode,
                targetAddress: targetAddress,
                viaPeripheral: peripheralIdentifier
            )
        } else {
            mgr.setCCTWithSleep(
                intensity: intensity,
                cctKelvin: cctKelvin,
                sleepMode: sleepMode,
                targetAddress: targetAddress,
                viaPeripheral: peripheralIdentifier
            )
        }
    }
}
