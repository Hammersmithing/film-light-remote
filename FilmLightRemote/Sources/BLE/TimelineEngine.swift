import Foundation
import Combine
import QuartzCore
import AVFoundation

/// Plays back a Timeline — sweeps a playhead and fires BLE commands when blocks are reached.
class TimelineEngine: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0

    weak var bleManager: BLEManager?

    private var displayLink: CADisplayLink?
    private var startWallTime: CFTimeInterval = 0
    private var startOffset: Double = 0
    private var timeline: Timeline?
    private var firedBlockIds: Set<UUID> = []
    private var endedBlockIds: Set<UUID> = []

    private var connectionSub: AnyCancellable?
    private var audioPlayer: AVAudioPlayer?

    /// LightState instances kept alive for software effect engines.
    private var activeEffectStates: [LightState] = []

    // MARK: - Playback Control

    func play(timeline: Timeline) {
        stop()
        self.timeline = timeline
        firedBlockIds.removeAll()
        endedBlockIds.removeAll()

        startOffset = currentTime
        startWallTime = CACurrentMediaTime()
        isPlaying = true

        // Start audio if the timeline has one
        if let fileId = timeline.audioFileId {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let audioURL = docs.appendingPathComponent(fileId)
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                let player = try AVAudioPlayer(contentsOf: audioURL)
                player.prepareToPlay()
                player.currentTime = currentTime
                player.play()
                audioPlayer = player
            } catch {
                print("Audio playback failed: \(error)")
            }
        }

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isPlaying = false
        audioPlayer?.stop()
        audioPlayer = nil
        connectionSub?.cancel()
        connectionSub = nil
        bleManager?.stopEffect()
        activeEffectStates.removeAll()
    }

    func seek(to time: Double) {
        let clamped = max(0, min(time, timeline?.totalDuration ?? 30))
        currentTime = clamped
        audioPlayer?.currentTime = clamped
        if isPlaying {
            startOffset = clamped
            startWallTime = CACurrentMediaTime()
            // Re-evaluate which blocks have already been fired
            rebuildFiredSets(upTo: clamped)
        }
    }

    // MARK: - Display Link

    @objc private func tick() {
        guard let tl = timeline else { return }

        let elapsed = CACurrentMediaTime() - startWallTime
        currentTime = startOffset + elapsed

        if currentTime >= tl.totalDuration {
            currentTime = tl.totalDuration
            stop()
            currentTime = 0
            return
        }

        // Check for blocks to fire
        var blocksToFire: [(TimelineTrack, TimelineBlock)] = []

        for track in tl.tracks {
            for block in track.blocks {
                // Fire block when playhead crosses its start time
                if block.startTime <= currentTime && !firedBlockIds.contains(block.id) {
                    firedBlockIds.insert(block.id)
                    blocksToFire.append((track, block))
                }

                // End block when playhead crosses startTime + duration (if duration > 0)
                if block.duration > 0 {
                    let endTime = block.startTime + block.duration
                    if endTime <= currentTime && !endedBlockIds.contains(block.id) {
                        endedBlockIds.insert(block.id)
                        // Dim this light to 0%
                        dimLight(track: track)
                    }
                }
            }
        }

        if !blocksToFire.isEmpty {
            fireBlocks(blocksToFire)
        }
    }

    // MARK: - Fire Blocks

    private func fireBlocks(_ blocks: [(TimelineTrack, TimelineBlock)]) {
        // Queue them sequentially like CueEngine.fireNextLight
        var remaining = blocks
        fireNextBlock(&remaining)
    }

    private func fireNextBlock(_ remaining: inout [(TimelineTrack, TimelineBlock)]) {
        guard let bm = bleManager, !remaining.isEmpty else { return }
        let (track, block) = remaining.removeFirst()
        let rest = remaining

        guard let saved = KeyStorage.shared.savedLights.first(where: { $0.id == track.lightId }) else {
            var mutableRest = rest
            fireNextBlock(&mutableRest)
            return
        }

        bm.targetUnicastAddress = track.unicastAddress

        if bm.connectedPeripheral?.identifier == saved.peripheralIdentifier,
           bm.connectionState == .ready {
            sendState(block.state, to: track.unicastAddress, bleManager: bm)
            var mutableRest = rest
            fireNextBlock(&mutableRest)
            return
        }

        bm.connectToKnownPeripheral(identifier: saved.peripheralIdentifier)

        connectionSub?.cancel()
        connectionSub = bm.$connectionState
            .filter { $0 == .ready }
            .first()
            .sink { [weak self] _ in
                self?.sendState(block.state, to: track.unicastAddress, bleManager: bm)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    var mutableRest = rest
                    self?.fireNextBlock(&mutableRest)
                }
            }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard self?.connectionSub != nil else { return }
            self?.connectionSub?.cancel()
            self?.connectionSub = nil
            var mutableRest = rest
            self?.fireNextBlock(&mutableRest)
        }
    }

    // MARK: - Send State (same logic as CueEngine)

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

    // MARK: - Dim Light

    private func dimLight(track: TimelineTrack) {
        guard let bm = bleManager else { return }
        guard let saved = KeyStorage.shared.savedLights.first(where: { $0.id == track.lightId }) else { return }

        bm.targetUnicastAddress = track.unicastAddress

        if bm.connectedPeripheral?.identifier == saved.peripheralIdentifier,
           bm.connectionState == .ready {
            bm.setCCTWithSleep(intensity: 0, cctKelvin: 5600, sleepMode: 0, targetAddress: track.unicastAddress)
            return
        }

        bm.connectToKnownPeripheral(identifier: saved.peripheralIdentifier)
        // Fire and forget for dims during playback — don't block the main queue
    }

    // MARK: - Helpers

    private func rebuildFiredSets(upTo time: Double) {
        guard let tl = timeline else { return }
        firedBlockIds.removeAll()
        endedBlockIds.removeAll()
        for track in tl.tracks {
            for block in track.blocks {
                if block.startTime <= time {
                    firedBlockIds.insert(block.id)
                }
                if block.duration > 0 && block.startTime + block.duration <= time {
                    endedBlockIds.insert(block.id)
                }
            }
        }
    }
}
