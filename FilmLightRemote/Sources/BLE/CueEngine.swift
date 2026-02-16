import Foundation
import Combine

/// Manages cue execution — fires cues via BLE mesh, handles fades and auto-follow.
class CueEngine: ObservableObject {
    @Published var currentCueIndex: Int = 0
    @Published var isRunning: Bool = false

    weak var bleManager: BLEManager?
    private var fadeTimer: Timer?
    private var delayWork: DispatchWorkItem?
    private var autoFollowWork: DispatchWorkItem?
    private var allCues: [Cue] = []

    /// LightState instances kept alive for software effect engines.
    /// Each engine holds a reference to its LightState for parameter updates.
    private var activeEffectStates: [LightState] = []

    // MARK: - Fire Cue

    func fireCue(_ cue: Cue, allCues: [Cue]) {
        guard let bm = bleManager else { return }
        self.allCues = allCues

        // Stop any in-progress fade, auto-follow, or software effect engines
        cancelPending()
        isRunning = true

        // Apply pre-execution delay, then execute
        let preDelay = cue.followDelay
        if preDelay > 0 {
            let work = DispatchWorkItem { [weak self] in
                self?.executeCue(cue, bleManager: bm)
            }
            delayWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + preDelay, execute: work)
        } else {
            executeCue(cue, bleManager: bm)
        }
    }

    /// Execute the cue's lights (after any pre-delay has elapsed).
    private func executeCue(_ cue: Cue, bleManager: BLEManager) {
        if cue.fadeTime > 0 {
            fireFade(cue, bleManager: bleManager)
        } else {
            fireSnap(cue, bleManager: bleManager)
        }

        // Advance to next cue index
        let nextIndex = currentCueIndex + 1
        let hasNext = nextIndex < allCues.count

        // Schedule auto-follow after the duration completes
        if cue.autoFollow && hasNext {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.currentCueIndex = nextIndex
                self.fireCue(allCues[nextIndex], allCues: allCues)
            }
            autoFollowWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + cue.fadeTime, execute: work)
        } else {
            // Move pointer to next (for the GO button)
            DispatchQueue.main.asyncAfter(deadline: .now() + cue.fadeTime + 0.1) { [weak self] in
                self?.isRunning = false
                if hasNext {
                    self?.currentCueIndex = nextIndex
                }
            }
        }
    }

    // MARK: - Snap (instant)

    private func fireSnap(_ cue: Cue, bleManager: BLEManager) {
        // Stagger commands slightly so the mesh proxy can process each one
        for (i, entry) in cue.lightEntries.enumerated() {
            let delay = Double(i) * 0.15
            if delay == 0 {
                sendState(entry.state, to: entry.unicastAddress, bleManager: bleManager)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.sendState(entry.state, to: entry.unicastAddress, bleManager: bleManager)
                }
            }
        }
    }

    // MARK: - Fade (interpolated)

    private func fireFade(_ cue: Cue, bleManager: BLEManager) {
        let fadeTime = cue.fadeTime
        let stepInterval: TimeInterval = 0.1 // 10 updates/sec
        let totalSteps = Int(fadeTime / stepInterval)
        guard totalSteps > 0 else {
            fireSnap(cue, bleManager: bleManager)
            return
        }

        struct FadeTarget {
            let entry: LightCueEntry
            let startIntensity: Double
            let startCCT: Double
            let startHue: Double
            let startSaturation: Double
        }

        var targets: [FadeTarget] = []
        for entry in cue.lightEntries {
            let startIntensity = entry.state.intensity
            let startCCT = entry.state.cctKelvin
            let startHue = entry.state.hue
            let startSat = entry.state.saturation

            let prevCueIndex = currentCueIndex - 1
            var si = startIntensity, sc = startCCT, sh = startHue, ss = startSat
            if prevCueIndex >= 0 && prevCueIndex < allCues.count {
                let prevCue = allCues[prevCueIndex]
                if let prevEntry = prevCue.lightEntries.first(where: { $0.lightId == entry.lightId }) {
                    si = prevEntry.state.intensity
                    sc = prevEntry.state.cctKelvin
                    sh = prevEntry.state.hue
                    ss = prevEntry.state.saturation
                }
            }

            targets.append(FadeTarget(
                entry: entry,
                startIntensity: si,
                startCCT: sc,
                startHue: sh,
                startSaturation: ss
            ))
        }

        var step = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            step += 1
            let progress = min(1.0, Double(step) / Double(totalSteps))

            for target in targets {
                let intensity = Self.lerp(target.startIntensity, target.entry.state.intensity, progress)
                let cct = Self.lerp(target.startCCT, target.entry.state.cctKelvin, progress)
                let hue = Self.lerp(target.startHue, target.entry.state.hue, progress)
                let sat = Self.lerp(target.startSaturation, target.entry.state.saturation, progress)

                let mode = LightMode(rawValue: target.entry.state.mode) ?? .cct
                let addr = target.entry.unicastAddress

                switch mode {
                case .cct:
                    bleManager.setCCTWithSleep(
                        intensity: intensity,
                        cctKelvin: Int(cct),
                        sleepMode: target.entry.state.isOn ? 1 : 0,
                        targetAddress: addr
                    )
                case .hsi:
                    bleManager.setHSIWithSleep(
                        intensity: intensity,
                        hue: Int(hue),
                        saturation: Int(sat),
                        cctKelvin: Int(target.entry.state.hsiCCT),
                        sleepMode: target.entry.state.isOn ? 1 : 0,
                        targetAddress: addr
                    )
                case .effects:
                    // For effects, snap to the target state at the end of fade
                    if progress >= 1.0 {
                        self?.sendState(target.entry.state, to: addr, bleManager: bleManager)
                    }
                }
            }

            if progress >= 1.0 {
                timer.invalidate()
                self?.fadeTimer = nil
            }
        }
    }

    // MARK: - Send State

    private func sendState(_ state: CueState, to address: UInt16, bleManager: BLEManager) {
        let mode = LightMode(rawValue: state.mode) ?? .cct

        if !state.isOn {
            bleManager.sendSleep(false, targetAddress: address)
            return
        }

        switch mode {
        case .cct:
            bleManager.setCCTWithSleep(
                intensity: state.intensity,
                cctKelvin: Int(state.cctKelvin),
                sleepMode: 1,
                targetAddress: address
            )
        case .hsi:
            bleManager.setHSIWithSleep(
                intensity: state.intensity,
                hue: Int(state.hue),
                saturation: Int(state.saturation),
                cctKelvin: Int(state.hsiCCT),
                sleepMode: 1,
                targetAddress: address
            )
        case .effects:
            sendEffect(state, to: address, bleManager: bleManager)
        }
    }

    // MARK: - Effect Execution

    private func sendEffect(_ state: CueState, to address: UInt16, bleManager: BLEManager) {
        let effect = LightEffect(rawValue: state.effectId) ?? .none

        if effect == .none {
            // No effect selected — fall back to CCT
            bleManager.setCCTWithSleep(
                intensity: state.intensity,
                cctKelvin: Int(state.cctKelvin),
                sleepMode: 1,
                targetAddress: address
            )
            return
        }

        // Build a LightState with all the cue's parameters so software engines
        // can read the full configuration (min/max, shape, frequency, colors, etc.)
        let ls = LightState()
        state.apply(to: ls)

        // Determine if this effect needs a software engine
        let needsSoftwareEngine: Bool
        switch effect {
        case .faultyBulb:
            needsSoftwareEngine = true  // always its own engine
        case .pulsing, .strobe, .party:
            needsSoftwareEngine = true  // always software
        case .paparazzi:
            needsSoftwareEngine = ls.paparazziColorMode == .hsi
        case .copCar:
            needsSoftwareEngine = false // hardware only
        default:
            // Other effects (TV, Candle, Fire, Lightning, etc.) use software engine
            // only in HSI color mode
            needsSoftwareEngine = ls.effectColorMode == .hsi
        }

        // Determine effect color mode for hardware commands
        let effectColorMode: Int
        switch effect {
        case .paparazzi:
            effectColorMode = state.paparazziColorMode == "HSI" ? 1 : 0
        case .strobe:
            effectColorMode = state.strobeColorMode == "HSI" ? 1 : 0
        case .faultyBulb:
            effectColorMode = state.faultyBulbColorMode == "HSI" ? 1 : 0
        default:
            effectColorMode = state.effectColorMode == "HSI" ? 1 : 0
        }

        // First ensure the light is on at the right base color
        if effectColorMode == 1 {
            bleManager.setHSIWithSleep(
                intensity: state.intensity,
                hue: Int(state.hue),
                saturation: Int(state.saturation),
                cctKelvin: Int(state.hsiCCT),
                sleepMode: 1,
                targetAddress: address
            )
        } else {
            bleManager.setCCTWithSleep(
                intensity: state.intensity,
                cctKelvin: Int(state.cctKelvin),
                sleepMode: 1,
                targetAddress: address
            )
        }

        if needsSoftwareEngine {
            // Start the appropriate software engine after a brief delay
            // to let the base state command arrive first
            let savedAddress = bleManager.targetUnicastAddress
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                // Point the engine at the right light
                bleManager.targetUnicastAddress = address

                switch effect {
                case .faultyBulb:
                    bleManager.startFaultyBulb(lightState: ls)
                case .paparazzi:
                    bleManager.startPaparazzi(lightState: ls)
                default:
                    // Pulsing, Strobe, Party, and HSI-mode effects
                    bleManager.startSoftwareEffect(lightState: ls)
                }

                // Restore previous address
                bleManager.targetUnicastAddress = savedAddress

                // Keep the LightState alive so the engine can reference it
                self.activeEffectStates.append(ls)
            }
        } else {
            // Hardware-only effect — send after a brief delay for the base state to arrive
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                bleManager.setEffect(
                    effectType: effect.rawValue,
                    intensityPercent: state.intensity,
                    frq: Int(state.effectFrequency),
                    cctKelvin: Int(state.cctKelvin),
                    copCarColor: state.copCarColor,
                    effectMode: effectColorMode,
                    hue: Int(state.hue),
                    saturation: Int(state.saturation),
                    targetAddress: address
                )
            }
        }
    }

    // MARK: - Reset

    func reset() {
        cancelPending()
        currentCueIndex = 0
        isRunning = false
    }

    private func cancelPending() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        delayWork?.cancel()
        delayWork = nil
        autoFollowWork?.cancel()
        autoFollowWork = nil

        // Stop all software effect engines
        bleManager?.stopEffect()
        activeEffectStates.removeAll()
    }

    // MARK: - Interpolation

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}
