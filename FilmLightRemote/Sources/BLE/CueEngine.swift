import Foundation
import Combine

/// Manages cue execution — fires cues via the bridge, handles timing and auto-follow.
///
/// Timing model per cue:
///   1. Delay — wait before the cue begins
///   2. Execute — send each light's state via bridge (all simultaneous)
///   3. Duration — how long the cue stays active (0 = hold indefinitely until next GO)
///   4. End — effects stop, lights dim to 0%, check if next cue has auto-start
class CueEngine: ObservableObject {
    @Published var currentCueIndex: Int = 0
    @Published var isRunning: Bool = false

    weak var bleManager: BLEManager?
    private var delayWork: DispatchWorkItem?
    private var durationWork: DispatchWorkItem?
    private var allCues: [Cue] = []

    // MARK: - Fire Cue

    func fireCue(_ cue: Cue, allCues: [Cue]) {
        guard let bm = bleManager else { return }
        self.allCues = allCues

        // Stop any in-progress work from the previous cue
        cancelPending()
        isRunning = true

        // Step 1: Apply pre-execution delay, then execute
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

    /// Step 2 & 3: Snap lights to their state immediately, then hold for duration.
    private func executeCue(_ cue: Cue, bleManager: BLEManager) {
        // Fire all lights simultaneously via bridge
        fireSnap(cue, bleManager: bleManager)

        // Schedule the cue end after duration
        let duration = cue.fadeTime
        let work = DispatchWorkItem { [weak self] in
            self?.cueDidEnd()
        }
        durationWork = work

        if duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        } else {
            // Duration 0 = hold indefinitely until next GO
            durationWork = nil
        }
    }

    /// Step 4: The current cue has finished its duration.
    private func cueDidEnd() {
        // Stop all effects and dim lights to 0%
        bleManager?.bridgeManager.stopAll()
        dimCueLights(allCues[currentCueIndex])

        let nextIndex = currentCueIndex + 1
        let hasNext = nextIndex < allCues.count

        if hasNext {
            let nextCue = allCues[nextIndex]
            currentCueIndex = nextIndex

            // If the next cue has "Start Upon End of Previous Cue", fire it
            if nextCue.autoFollow {
                fireCue(nextCue, allCues: allCues)
            } else {
                // Advance pointer for the GO button but stop running
                isRunning = false
            }
        } else {
            isRunning = false
        }
    }

    // MARK: - Snap (send all lights via bridge simultaneously)

    private func fireSnap(_ cue: Cue, bleManager: BLEManager) {
        for entry in cue.lightEntries {
            bleManager.targetUnicastAddress = entry.unicastAddress
            sendState(entry.state, to: entry.unicastAddress, bleManager: bleManager)
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
            bleManager.setCCTWithSleep(
                intensity: state.intensity,
                cctKelvin: Int(state.cctKelvin),
                sleepMode: 1,
                targetAddress: address
            )
            return
        }

        let ls = LightState()
        state.apply(to: ls)

        let needsSoftwareEngine: Bool
        switch effect {
        case .faultyBulb:
            needsSoftwareEngine = true
        case .pulsing, .strobe, .party:
            needsSoftwareEngine = true
        case .paparazzi:
            needsSoftwareEngine = ls.paparazziColorMode == .hsi
        case .copCar:
            needsSoftwareEngine = false
        default:
            needsSoftwareEngine = ls.effectColorMode == .hsi
        }

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

        // Set base color first
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
            let savedAddress = bleManager.targetUnicastAddress
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard self != nil else { return }
                bleManager.targetUnicastAddress = address

                let params = BridgeManager.effectParams(from: ls, effect: effect)
                bleManager.bridgeManager.startSoftwareEffect(
                    unicast: address,
                    engine: BridgeManager.engineName(for: effect),
                    params: params
                )

                bleManager.targetUnicastAddress = savedAddress
            }
        } else {
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

    // MARK: - Dim Lights

    /// Send 0% intensity to every light in the given cue for a clean break between cues.
    private func dimCueLights(_ cue: Cue) {
        guard let bm = bleManager else { return }
        for entry in cue.lightEntries {
            bm.bridgeManager.setCCT(unicast: entry.unicastAddress, intensity: 0, cctKelvin: 5600, sleepMode: 0)
        }
    }

    // MARK: - Stop / Reset

    func stop() {
        cancelPending()
        // Dim all lights from the current cue
        if currentCueIndex < allCues.count {
            dimCueLights(allCues[currentCueIndex])
        }
        isRunning = false
    }

    func reset() {
        cancelPending()
        currentCueIndex = 0
        isRunning = false
    }

    private func cancelPending() {
        delayWork?.cancel()
        delayWork = nil
        durationWork?.cancel()
        durationWork = nil
        bleManager?.bridgeManager.stopAll()
    }

}
