import Foundation
import Combine

/// Manages cue execution — fires cues via BLE, handles timing and auto-follow.
///
/// Timing model per cue:
///   1. Delay — wait before the cue begins
///   2. Execute — connect to each light and snap to prescribed state
///   3. Duration — how long the cue stays active (0 = hold indefinitely until next GO)
///   4. End — effects stop, lights dim to 0%, check if next cue has auto-start
class CueEngine: ObservableObject {
    @Published var currentCueIndex: Int = 0
    @Published var isRunning: Bool = false

    weak var bleManager: BLEManager?
    private var delayWork: DispatchWorkItem?
    private var durationWork: DispatchWorkItem?
    private var allCues: [Cue] = []
    private var connectionSub: AnyCancellable?

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
        // Fire lights — connects to each one directly
        fireSnap(cue, bleManager: bleManager)

        // Schedule the cue end after duration (fadeTime = duration in seconds)
        // Add extra time to account for sequential light connections
        let connectionTime = Double(cue.lightEntries.count) * 1.5
        let duration = cue.fadeTime
        let work = DispatchWorkItem { [weak self] in
            self?.cueDidEnd()
        }
        durationWork = work

        if duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + connectionTime + duration, execute: work)
        } else {
            // Duration 0 = hold indefinitely until next GO
            durationWork = nil
        }
    }

    /// Step 4: The current cue has finished its duration.
    private func cueDidEnd() {
        // Stop software effect engines and dim lights to 0% for a clean break
        bleManager?.stopEffect()
        bleManager?.disconnectAllExtra()
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

    // MARK: - Snap (connect to each light and send)

    private func fireSnap(_ cue: Cue, bleManager: BLEManager) {
        // When bridge is connected, send all commands immediately without sequential BLE connections
        if bleManager.bridgeManager.isConnected {
            for entry in cue.lightEntries {
                bleManager.targetUnicastAddress = entry.unicastAddress
                sendState(entry.state, to: entry.unicastAddress, bleManager: bleManager)
            }
            return
        }

        // Build a queue of light entries to process sequentially
        var remaining = Array(cue.lightEntries)
        fireNextLight(&remaining, bleManager: bleManager)
    }

    /// Connect to the next light, wait for ready, send its state, then continue.
    private func fireNextLight(_ remaining: inout [LightCueEntry], bleManager: BLEManager) {
        guard !remaining.isEmpty else { return }
        let entry = remaining.removeFirst()
        let rest = remaining // capture for the closure

        // Look up the saved light to get its peripheral identifier
        guard let saved = KeyStorage.shared.savedLights.first(where: { $0.id == entry.lightId }) else {
            // Can't find saved light — skip and continue
            var mutableRest = rest
            fireNextLight(&mutableRest, bleManager: bleManager)
            return
        }

        bleManager.targetUnicastAddress = entry.unicastAddress

        // Always go through connectToKnownPeripheral — it handles:
        // - Already primary: sets .ready synchronously
        // - In peripheral registry: promotes to primary, sets .ready synchronously
        // - Fresh connection: sets .connecting, .ready fires later via delegate
        bleManager.connectToKnownPeripheral(identifier: saved.peripheralIdentifier, keepExisting: true)

        connectionSub?.cancel()
        connectionSub = bleManager.$connectionState
            .filter { $0 == .ready }
            .first()
            .sink { [weak self] _ in
                self?.sendState(entry.state, to: entry.unicastAddress, bleManager: bleManager)
                // Continue to next light after a pause (allows 0.2s engine start to complete)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    var mutableRest = rest
                    self?.fireNextLight(&mutableRest, bleManager: bleManager)
                }
            }

        // Safety timeout — don't get stuck if connection fails
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard self?.connectionSub != nil else { return }
            self?.connectionSub?.cancel()
            self?.connectionSub = nil
            var mutableRest = rest
            self?.fireNextLight(&mutableRest, bleManager: bleManager)
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
            // Capture the peripheral ID NOW — connectedPeripheral may change by the time the delay fires
            let peripheralId = bleManager.connectedPeripheral?.identifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                bleManager.targetUnicastAddress = address

                switch effect {
                case .faultyBulb:
                    bleManager.startFaultyBulb(lightState: ls, peripheralIdentifier: peripheralId)
                case .paparazzi:
                    bleManager.startPaparazzi(lightState: ls, peripheralIdentifier: peripheralId)
                default:
                    bleManager.startSoftwareEffect(lightState: ls, peripheralIdentifier: peripheralId)
                }

                bleManager.targetUnicastAddress = savedAddress
                self.activeEffectStates.append(ls)
            }
        } else {
            // Capture peripheral ID for the delayed hardware effect send
            let peripheralId = bleManager.connectedPeripheral?.identifier
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
                    targetAddress: address,
                    viaPeripheral: peripheralId
                )
            }
        }
    }

    // MARK: - Dim Lights

    /// Send 0% intensity to every light in the given cue for a clean break between cues.
    private func dimCueLights(_ cue: Cue) {
        guard let bm = bleManager else { return }

        // When bridge is connected, send all dim commands immediately
        if bm.bridgeManager.isConnected {
            for entry in cue.lightEntries {
                bm.bridgeManager.setCCT(unicast: entry.unicastAddress, intensity: 0, cctKelvin: 5600, sleepMode: 0)
            }
            return
        }

        var remaining = Array(cue.lightEntries)
        dimNextLight(&remaining, bleManager: bm)
    }

    private func dimNextLight(_ remaining: inout [LightCueEntry], bleManager: BLEManager) {
        guard !remaining.isEmpty else { return }
        let entry = remaining.removeFirst()
        let rest = remaining

        guard let saved = KeyStorage.shared.savedLights.first(where: { $0.id == entry.lightId }) else {
            var mutableRest = rest
            dimNextLight(&mutableRest, bleManager: bleManager)
            return
        }

        bleManager.targetUnicastAddress = entry.unicastAddress

        if bleManager.connectedPeripheral?.identifier == saved.peripheralIdentifier,
           bleManager.connectionState == .ready {
            bleManager.setCCTWithSleep(intensity: 0, cctKelvin: 5600, sleepMode: 0, targetAddress: entry.unicastAddress)
            var mutableRest = rest
            dimNextLight(&mutableRest, bleManager: bleManager)
            return
        }

        bleManager.connectToKnownPeripheral(identifier: saved.peripheralIdentifier)

        connectionSub?.cancel()
        connectionSub = bleManager.$connectionState
            .filter { $0 == .ready }
            .first()
            .sink { [weak self] _ in
                bleManager.setCCTWithSleep(intensity: 0, cctKelvin: 5600, sleepMode: 0, targetAddress: entry.unicastAddress)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    var mutableRest = rest
                    self?.dimNextLight(&mutableRest, bleManager: bleManager)
                }
            }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard self?.connectionSub != nil else { return }
            self?.connectionSub?.cancel()
            self?.connectionSub = nil
            var mutableRest = rest
            self?.dimNextLight(&mutableRest, bleManager: bleManager)
        }
    }

    // MARK: - Reset

    func reset() {
        cancelPending()
        currentCueIndex = 0
        isRunning = false
    }

    private func cancelPending() {
        connectionSub?.cancel()
        connectionSub = nil
        delayWork?.cancel()
        delayWork = nil
        durationWork?.cancel()
        durationWork = nil

        if let bm = bleManager, bm.bridgeManager.isConnected {
            bm.bridgeManager.stopAll()
        } else {
            bleManager?.stopEffect()
            bleManager?.disconnectAllExtra()
        }
        activeEffectStates.removeAll()
    }

}
