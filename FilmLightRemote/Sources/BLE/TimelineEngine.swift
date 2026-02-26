import Foundation
import Combine
import QuartzCore
import AVFoundation

/// Plays back a Timeline — sweeps a playhead and fires BLE commands when blocks are reached.
class TimelineEngine: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var currentBeat: Double = 0.0

    weak var bleManager: BLEManager?

    private var displayLink: CADisplayLink?
    private var startWallTime: CFTimeInterval = 0
    private var startOffset: Double = 0
    private var timeline: Timeline?
    private var firedBlockIds: Set<UUID> = []
    private var endedBlockIds: Set<UUID> = []

    private var audioPlayer: AVAudioPlayer?

    /// LightState instances kept alive for software effect engines.
    private var activeEffectStates: [LightState] = []

    // Beat mode
    private var tempoMap: TempoMap?
    private let metronome = MetronomeEngine()
    private var previousTime: Double = 0
    private var effectiveDuration: Double = 0

    // MARK: - Playback Control

    func play(timeline: Timeline) {
        stop()
        self.timeline = timeline
        firedBlockIds.removeAll()
        endedBlockIds.removeAll()

        // Build TempoMap for beat mode
        if timeline.effectiveMode == .beats {
            tempoMap = TempoMap(events: timeline.effectiveTempoEvents)
            effectiveDuration = tempoMap!.totalSeconds(forBeats: timeline.totalBeats ?? 32)
            currentBeat = tempoMap!.beat(forSeconds: currentTime)
        } else {
            tempoMap = nil
            effectiveDuration = timeline.totalDuration
        }

        previousTime = currentTime
        startOffset = currentTime
        startWallTime = CACurrentMediaTime()
        isPlaying = true

        // Setup metronome if enabled in beat mode
        if timeline.effectiveMode == .beats && timeline.metronomeEnabled == true {
            metronome.setup()
        }

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
        bleManager?.stopEffect()
        activeEffectStates.removeAll()
        metronome.stop()
        tempoMap = nil
    }

    func setMetronomeEnabled(_ enabled: Bool) {
        timeline?.metronomeEnabled = enabled
        if enabled {
            metronome.setup()  // no-op if already set up
        }
    }

    func seek(to time: Double) {
        let maxTime = effectiveDuration > 0 ? effectiveDuration : (timeline?.totalDuration ?? 30)
        let clamped = max(0, min(time, maxTime))
        currentTime = clamped
        previousTime = clamped
        audioPlayer?.currentTime = clamped
        if let map = tempoMap {
            currentBeat = map.beat(forSeconds: clamped)
        }
        metronome.reset()
        if isPlaying {
            startOffset = clamped
            startWallTime = CACurrentMediaTime()
            rebuildFiredSets(upTo: clamped)
        }
    }

    // MARK: - Display Link

    @objc private func tick() {
        guard let tl = timeline else { return }

        let prevTime = currentTime
        let elapsed = CACurrentMediaTime() - startWallTime
        currentTime = startOffset + elapsed

        let duration = effectiveDuration > 0 ? effectiveDuration : tl.totalDuration
        if currentTime >= duration {
            currentTime = duration
            stop()
            currentTime = 0
            currentBeat = 0
            return
        }

        // Update beat position and tick metronome
        if let map = tempoMap {
            currentBeat = map.beat(forSeconds: currentTime)
            if tl.metronomeEnabled == true {
                metronome.tick(previousTime: prevTime, currentTime: currentTime, tempoMap: map)
            }
        }
        previousTime = currentTime

        // Check for blocks to fire
        let isBeatMode = tl.effectiveMode == .beats
        var blocksToFire: [(TimelineTrack, TimelineBlock)] = []

        for track in tl.tracks {
            for block in track.blocks {
                // In beat mode, block positions are in beats — convert to seconds
                let blockStartSec = isBeatMode ? tempoMap!.seconds(forBeat: block.startTime) : block.startTime
                let blockEndSec = isBeatMode ? tempoMap!.seconds(forBeat: block.startTime + block.duration) : (block.startTime + block.duration)

                if blockStartSec <= currentTime && !firedBlockIds.contains(block.id) {
                    firedBlockIds.insert(block.id)
                    blocksToFire.append((track, block))
                }

                if block.duration > 0 {
                    if blockEndSec <= currentTime && !endedBlockIds.contains(block.id) {
                        endedBlockIds.insert(block.id)
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
        guard let bm = bleManager else { return }
        for (track, block) in blocks {
            bm.targetUnicastAddress = track.unicastAddress
            sendState(block.state, to: track.unicastAddress, bleManager: bm)
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
        bm.targetUnicastAddress = track.unicastAddress
        bm.setCCTWithSleep(intensity: 0, cctKelvin: 5600, sleepMode: 0, targetAddress: track.unicastAddress)
    }

    // MARK: - Helpers

    private func rebuildFiredSets(upTo time: Double) {
        guard let tl = timeline else { return }
        let isBeatMode = tl.effectiveMode == .beats
        firedBlockIds.removeAll()
        endedBlockIds.removeAll()
        for track in tl.tracks {
            for block in track.blocks {
                let startSec = isBeatMode ? tempoMap?.seconds(forBeat: block.startTime) ?? block.startTime : block.startTime
                let endSec = isBeatMode ? tempoMap?.seconds(forBeat: block.startTime + block.duration) ?? (block.startTime + block.duration) : (block.startTime + block.duration)
                if startSec <= time {
                    firedBlockIds.insert(block.id)
                }
                if block.duration > 0 && endSec <= time {
                    endedBlockIds.insert(block.id)
                }
            }
        }
    }
}
