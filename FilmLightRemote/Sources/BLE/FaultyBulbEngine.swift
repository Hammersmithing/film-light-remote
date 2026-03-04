import Foundation

// MARK: - Faulty Bulb Software Engine
/// Sends random intensity values within a range at irregular intervals,
/// simulating a realistic faulty/flickering bulb effect.
/// Self-contained: stores its own copies of all parameters and target address
/// so it keeps running even after the light session view is dismissed.
class FaultyBulbEngine {
    private var workItem: DispatchWorkItem?
    private var bleManager: BLEManager? // Strong ref — engine outlives the view
    private var currentIntensity: Double = 50.0
    /// Dedicated background queue so the engine keeps running when the app is backgrounded
    private let queue = DispatchQueue(label: "com.filmlightremote.faultybulb", qos: .userInitiated)

    // Stored parameters — engine is self-contained, does not depend on LightState
    private(set) var targetAddress: UInt16 = 0x0002
    /// The peripheral this engine writes through (set at start time).
    private(set) var peripheralIdentifier: UUID = UUID()
    private var colorMode: LightMode = .cct
    private var cctKelvin: Int = 5600
    private var hue: Int = 0
    private var saturation: Int = 100
    private var hsiCCT: Int = 5600
    private var minIntensity: Double = 20.0
    private var maxIntensity: Double = 100.0
    private var biasValue: Double = 100.0
    private var recoveryValue: Double = 100.0
    private var warmthValue: Double = 0.0
    private var warmestCCT: Int = 2700
    private var pointCount: Int = 2
    private var transitionValue: Double = 0.0
    private var frequencyValue: Double = 5.0

    func start(bleManager: BLEManager, lightState: LightState, targetAddress: UInt16, peripheralIdentifier: UUID? = nil) {
        stop()
        self.bleManager = bleManager
        self.targetAddress = targetAddress
        self.peripheralIdentifier = peripheralIdentifier ?? bleManager.connectedPeripheral?.identifier ?? UUID()
        self.currentIntensity = lightState.intensity
        updateParams(from: lightState)
        fireEvent()
    }

    func stop() {
        workItem?.cancel()
        workItem = nil
        bleManager = nil
    }

    /// Update stored parameters from lightState (called when user adjusts sliders while view is open)
    func updateParams(from lightState: LightState) {
        colorMode = lightState.faultyBulbColorMode
        cctKelvin = Int(lightState.cctKelvin)
        hue = Int(lightState.hue)
        saturation = Int(lightState.saturation)
        hsiCCT = Int(lightState.hsiCCT)
        minIntensity = lightState.faultyBulbMin
        maxIntensity = lightState.faultyBulbMax
        biasValue = lightState.faultyBulbBias
        recoveryValue = lightState.faultyBulbRecovery
        warmthValue = lightState.faultyBulbWarmth
        warmestCCT = Int(lightState.warmestCCT)
        pointCount = Int(lightState.faultyBulbPoints)
        transitionValue = lightState.faultyBulbTransition
        frequencyValue = lightState.faultyBulbFrequency
    }

    /// Send intensity via CCT or HSI depending on color mode, using stored target address.
    /// When warmth > 0, the CCT shifts warmer proportional to how deep the intensity dip is.
    private func sendIntensity(_ percent: Double, sleepMode: Int) {
        guard let mgr = bleManager else { return }

        // Linear warmth shift: at warmth=100, CCT maps linearly from baseCCT
        // (at max intensity) to warmestCCT (at min intensity). Warmth slider
        // controls how far toward warmestCCT the low end reaches.
        let adjustedCCT: Int
        if warmthValue > 0 && maxIntensity > minIntensity {
            let dipDepth = max(0, min(1, (maxIntensity - percent) / (maxIntensity - minIntensity)))
            let shift = dipDepth * (warmthValue / 100.0)
            let baseCCT = colorMode == .hsi ? hsiCCT : cctKelvin
            adjustedCCT = Int(Double(baseCCT) + Double(warmestCCT - baseCCT) * shift)
            mgr.log("FaultyBulb warmth: i=\(Int(percent))% dip=\(String(format:"%.2f",dipDepth)) shift=\(String(format:"%.2f",shift)) base=\(baseCCT)K warm=\(warmestCCT)K → \(adjustedCCT)K")
        } else {
            adjustedCCT = colorMode == .hsi ? hsiCCT : cctKelvin
        }

        if colorMode == .hsi {
            mgr.setHSIWithSleep(
                intensity: percent,
                hue: hue,
                saturation: saturation,
                cctKelvin: adjustedCCT,
                sleepMode: sleepMode,
                targetAddress: targetAddress,
                viaPeripheral: peripheralIdentifier
            )
        } else {
            mgr.setCCTWithSleep(
                intensity: percent,
                cctKelvin: adjustedCCT,
                sleepMode: sleepMode,
                targetAddress: targetAddress,
                viaPeripheral: peripheralIdentifier
            )
        }
    }

    /// Build the discrete intensity levels from the range and point count
    private func discretePoints() -> [Double] {
        let lo = min(minIntensity, maxIntensity)
        let hi = max(minIntensity, maxIntensity)
        let n = max(2, pointCount)
        if n <= 1 || lo == hi { return [lo] }
        return (0..<n).map { i in
            lo + (hi - lo) * Double(i) / Double(n - 1)
        }
    }

    /// The main loop: wait for the frequency interval, then fire an event
    private func scheduleNextEvent() {
        guard bleManager != nil else { return }

        let freq = Int(frequencyValue)
        let interval: Double

        if freq >= 10 {
            // R = random wait each time
            interval = Double.random(in: 0.08...2.0)
        } else {
            // 1-9: exponential curve, 1 = slow ~1.5s, 9 = fast ~0.08s
            let base = 1.5 * pow(0.65, Double(freq - 1))
            interval = base * Double.random(in: 0.85...1.15)
        }

        let work = DispatchWorkItem { [weak self] in
            self?.fireEvent()
        }
        workItem = work
        queue.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// Fire one flicker event: pick a new point and go there (snap or fade).
    /// The fault bias slider is the primary control — it decides whether the
    /// bulb dips at all and overrides all other point-selection rules.
    private func fireEvent() {
        guard bleManager != nil else { return }

        let points = discretePoints()
        let hi = points.last ?? 50.0
        // Log-scaled: slider 0-100 → effective probability 0-1.0
        // pow(x, 2.5) gives fine control at low values:
        // slider 5 → 0.006, slider 15 → 0.009, slider 30 → 0.05, slider 50 → 0.18, slider 100 → 1.0
        let bias = pow(biasValue / 100.0, 2.5)

        // Bias 0 = not faulty at all → always stay at the highest point
        if bias <= 0 {
            if abs(currentIntensity - hi) > 0.5 {
                currentIntensity = hi
                sendIntensity(hi, sleepMode: 1)
            }
            scheduleNextEvent()
            return
        }

        let target: Double

        // Are we currently on the high point?
        let onHigh = abs(currentIntensity - hi) < 0.5

        if onHigh {
            // Decide whether to dip. Bias controls the probability of dipping.
            // bias=0.1 → 10% chance to dip, bias=1.0 → 100% chance to dip
            if Double.random(in: 0...1) < bias {
                // Dip to a lower point
                let lowerPoints = points.filter { $0 < hi - 0.5 }
                target = lowerPoints.randomElement() ?? hi
            } else {
                // Stay high — no flicker this cycle
                scheduleNextEvent()
                return
            }
        } else {
            // We're on a low point — recovery slider controls how quickly we return to high.
            // recovery=100 → always return to high (instant recovery)
            // recovery=0 → stay at low points (elongated dips)
            let returnChance = 0.10 + 0.90 * pow(recoveryValue / 100.0, 2.0)
            if Double.random(in: 0...1) < returnChance {
                target = hi
            } else {
                // Stay at a low point — either current or pick another one
                let lowerPoints = points.filter { $0 < hi - 0.5 }
                target = lowerPoints.randomElement() ?? hi
            }
        }

        let lo = min(minIntensity, maxIntensity)

        if transitionValue < 0.005 {
            // Instant snap — use sleepMode toggling for hard cut.
            // Going to the lowest point: sleep=0 (instant off).
            // Going to any higher point: sleep=1 (on) with that intensity.
            currentIntensity = target
            if target <= lo && lo < 1.0 {
                sendIntensity(0, sleepMode: 0)
            } else {
                sendIntensity(target, sleepMode: 1)
            }
            scheduleNextEvent()
        } else {
            // Fade to target over transition duration (value is already in seconds)
            let stepInterval: Double = 0.02
            let totalSteps = max(1, Int(transitionValue / stepInterval))
            fadeToTarget(target: target, stepsRemaining: totalSteps, stepInterval: stepInterval)
        }
    }

    /// Incrementally step toward the target intensity, then schedule next event
    private func fadeToTarget(target: Double, stepsRemaining: Int, stepInterval: Double) {
        guard stepsRemaining > 0 else {
            currentIntensity = target
            sendIntensity(target, sleepMode: 1)
            scheduleNextEvent()
            return
        }

        let interpolated = currentIntensity + (target - currentIntensity) / Double(stepsRemaining)
        currentIntensity = interpolated
        sendIntensity(interpolated, sleepMode: 1)

        let work = DispatchWorkItem { [weak self] in
            self?.fadeToTarget(target: target, stepsRemaining: stepsRemaining - 1, stepInterval: stepInterval)
        }
        workItem = work
        queue.asyncAfter(deadline: .now() + stepInterval, execute: work)
    }
}
