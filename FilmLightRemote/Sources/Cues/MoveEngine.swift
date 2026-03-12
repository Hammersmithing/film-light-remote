import Foundation
import Combine

/// Manages move execution — fires moves via BLE, handles fade interpolation and chaining.
///
/// Two playback modes:
///   - playAll: runs all moves sequentially with wait times between them
///   - next: fires the current move only, advances index, stops
///
/// Lights always hold at their final position — no dimming on end.
class MoveEngine: ObservableObject {
    @Published var currentMoveIndex: Int = 0
    @Published var isRunning: Bool = false

    weak var bleManager: BLEManager?
    private var waitWork: DispatchWorkItem?
    private var fadeTimer: Timer?
    private var allMoves: [Move] = []
    private var playingAll: Bool = false

    // MARK: - Public API

    /// Run all moves from currentMoveIndex to the end.
    func playAll(moves: [Move]) {
        allMoves = moves
        playingAll = true
        fireCurrentMove()
    }

    /// Fire the current move only, then stop.
    func playNext(moves: [Move]) {
        allMoves = moves
        playingAll = false
        fireCurrentMove()
    }

    func stop() {
        cancelPending()
        isRunning = false
    }

    func reset() {
        cancelPending()
        currentMoveIndex = 0
        isRunning = false
    }

    // MARK: - Fire Move

    private func fireCurrentMove() {
        guard let bm = bleManager else { return }
        guard currentMoveIndex < allMoves.count else {
            isRunning = false
            return
        }

        cancelPending()
        isRunning = true

        let move = allMoves[currentMoveIndex]
        executeMove(move, bleManager: bm)
    }

    private func executeMove(_ move: Move, bleManager: BLEManager) {
        if move.fadeTime > 0 && !move.lightEntries.isEmpty {
            startFade(move, bleManager: bleManager)
        } else {
            // Snap — send all lights to their "to" state immediately
            for entry in move.lightEntries {
                sendState(entry.toState, to: entry.unicastAddress, bleManager: bleManager)
            }
            moveDidComplete()
        }
    }

    // MARK: - Fade

    private func startFade(_ move: Move, bleManager: BLEManager) {
        // Send all lights to their "from" state immediately
        for entry in move.lightEntries {
            sendState(entry.fromState, to: entry.unicastAddress, bleManager: bleManager)
        }

        let fadeTime = move.fadeTime
        let startTime = Date()
        let tickInterval: TimeInterval = 0.05

        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)
            let t = min(elapsed / fadeTime, 1.0)

            for entry in move.lightEntries {
                let interpolated = CueState.interpolate(from: entry.fromState, to: entry.toState, t: t)
                self.sendState(interpolated, to: entry.unicastAddress, bleManager: bleManager)
            }

            if t >= 1.0 {
                timer.invalidate()
                self.fadeTimer = nil
                self.moveDidComplete()
            }
        }
    }

    // MARK: - Move Complete

    private func moveDidComplete() {
        let completedMove = allMoves[currentMoveIndex]
        if completedMove.lightsOffAfter, let bm = bleManager {
            for entry in completedMove.lightEntries {
                bm.sendSleep(false, targetAddress: entry.unicastAddress)
            }
        }

        let nextIndex = currentMoveIndex + 1
        let hasNext = nextIndex < allMoves.count

        if playingAll && hasNext {
            currentMoveIndex = nextIndex
            let waitTime = allMoves[nextIndex].waitTime
            if waitTime > 0 {
                let work = DispatchWorkItem { [weak self] in
                    self?.fireCurrentMove()
                }
                waitWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime, execute: work)
            } else {
                fireCurrentMove()
            }
        } else {
            if hasNext {
                currentMoveIndex = nextIndex
            }
            isRunning = false
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

                if bleManager.useBridge {
                    let params = BridgeManager.effectParams(from: ls, effect: effect)
                    bleManager.bridgeManager.startSoftwareEffect(
                        unicast: address,
                        engine: BridgeManager.engineName(for: effect),
                        params: params
                    )
                } else {
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

    // MARK: - Cancel

    private func cancelPending() {
        waitWork?.cancel()
        waitWork = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        if let bm = bleManager {
            if bm.useBridge {
                bm.bridgeManager.stopAll()
            } else {
                bm.stopEffect()
            }
        }
    }
}
