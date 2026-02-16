import Foundation
import Combine

/// Manages cue execution — fires cues via BLE mesh, handles timing and auto-follow.
///
/// Timing model per cue:
///   1. Delay — wait before the cue begins
///   2. Execute — snap lights to their prescribed state immediately
///   3. Duration — how long the cue stays active (0 = hold indefinitely until next GO)
///   4. End — effects stop, check if next cue has "Start Upon End of Previous Cue"
class CueEngine: ObservableObject {
    @Published var currentCueIndex: Int = 0
    @Published var isRunning: Bool = false

    weak var bleManager: BLEManager?
    private var delayWork: DispatchWorkItem?
    private var durationWork: DispatchWorkItem?
    private var allCues: [Cue] = []

    /// LightState instances kept alive for software effect engines.
    private var activeEffectStates: [LightState] = []

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
        // Always snap — send all light states immediately
        fireSnap(cue, bleManager: bleManager)

        // Schedule the cue end after duration (fadeTime = duration in seconds)
        let duration = cue.fadeTime
        let work = DispatchWorkItem { [weak self] in
            self?.cueDidEnd()
        }
        durationWork = work

        if duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        } else {
            // Duration 0 = hold indefinitely until next GO or auto-follow from another cue
            // Don't schedule an end — the cue stays active
            durationWork = nil
        }
    }

    /// Step 4: The current cue has finished its duration.
    private func cueDidEnd() {
        // Stop software effect engines and dim lights to 0% for a clean break
        bleManager?.stopEffect()
        activeEffectStates.removeAll()
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

    // MARK: - Snap (instant)

    private func fireSnap(_ cue: Cue, bleManager: BLEManager) {
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
                guard let self = self else { return }
                bleManager.targetUnicastAddress = address

                switch effect {
                case .faultyBulb:
                    bleManager.startFaultyBulb(lightState: ls)
                case .paparazzi:
                    bleManager.startPaparazzi(lightState: ls)
                default:
                    bleManager.startSoftwareEffect(lightState: ls)
                }

                bleManager.targetUnicastAddress = savedAddress
                self.activeEffectStates.append(ls)
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

        for (i, entry) in cue.lightEntries.enumerated() {
            let delay = Double(i) * 0.15
            if delay == 0 {
                bm.setCCTWithSleep(intensity: 0, cctKelvin: 5600, sleepMode: 0, targetAddress: entry.unicastAddress)
            } else {
                let addr = entry.unicastAddress
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    bm.setCCTWithSleep(intensity: 0, cctKelvin: 5600, sleepMode: 0, targetAddress: addr)
                }
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
        delayWork?.cancel()
        delayWork = nil
        durationWork?.cancel()
        durationWork = nil

        bleManager?.stopEffect()
        activeEffectStates.removeAll()
    }

}
