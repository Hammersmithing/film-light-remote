import Foundation

// MARK: - Move List

struct MoveList: Identifiable, Codable {
    let id: UUID
    var name: String
    var moves: [Move]

    init(id: UUID = UUID(), name: String = "New Move List", moves: [Move] = []) {
        self.id = id
        self.name = name
        self.moves = moves
    }

    /// Backward-compatible decoder: reads old CueList JSON and converts to MoveList.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)

        // Try new format first, fall back to legacy
        if let newMoves = try? c.decode([Move].self, forKey: .moves) {
            moves = newMoves
        } else if let legacyCues = try? c.decode([LegacyCue].self, forKey: .cues) {
            moves = Self.migrate(legacyCues)
        } else {
            moves = []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, moves, cues
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(moves, forKey: .moves)
    }

    /// Convert legacy Cue array to Move array.
    private static func migrate(_ cues: [LegacyCue]) -> [Move] {
        var moves: [Move] = []
        for (i, cue) in cues.enumerated() {
            let entries: [MoveLightEntry] = cue.lightEntries.map { entry in
                let fromState: CueState
                if let startState = entry.startState {
                    fromState = startState
                } else if i > 0,
                          let prev = cues[i - 1].lightEntries.first(where: { $0.lightId == entry.lightId }) {
                    fromState = prev.state
                } else {
                    fromState = entry.state
                }
                return MoveLightEntry(
                    lightId: entry.lightId,
                    lightName: entry.lightName,
                    unicastAddress: entry.unicastAddress,
                    fromState: fromState,
                    toState: entry.state
                )
            }
            moves.append(Move(
                name: cue.name,
                lightEntries: entries,
                fadeTime: (cue.fadeInTime ?? 0) > 0 ? (cue.fadeInTime ?? 0) : 0,
                waitTime: cue.followDelay
            ))
        }
        return moves
    }
}

/// Legacy types for migration only — not used elsewhere.
private struct LegacyCue: Codable {
    let id: UUID
    var name: String
    var lightEntries: [LegacyLightCueEntry]
    var fadeTime: Double
    var autoFollow: Bool
    var followDelay: Double
    var fadeInTime: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lightEntries = try c.decode([LegacyLightCueEntry].self, forKey: .lightEntries)
        fadeTime = try c.decode(Double.self, forKey: .fadeTime)
        autoFollow = try c.decode(Bool.self, forKey: .autoFollow)
        followDelay = try c.decode(Double.self, forKey: .followDelay)
        fadeInTime = try c.decodeIfPresent(Double.self, forKey: .fadeInTime)
    }
}

private struct LegacyLightCueEntry: Codable {
    let id: UUID
    var lightId: UUID
    var lightName: String
    var unicastAddress: UInt16
    var state: CueState
    var startState: CueState?
}

// MARK: - Move

struct Move: Identifiable, Codable {
    let id: UUID
    var name: String
    var lightEntries: [MoveLightEntry]
    var fadeTime: Double       // A→B transition duration (0 = snap)
    var waitTime: Double       // pause after this move before next move starts
    var lightsOffAfter: Bool   // turn lights off when move completes

    init(id: UUID = UUID(), name: String = "Move", lightEntries: [MoveLightEntry] = [],
         fadeTime: Double = 0, waitTime: Double = 0, lightsOffAfter: Bool = false) {
        self.id = id
        self.name = name
        self.lightEntries = lightEntries
        self.fadeTime = fadeTime
        self.waitTime = waitTime
        self.lightsOffAfter = lightsOffAfter
    }
}

// MARK: - Move Light Entry

struct MoveLightEntry: Identifiable, Codable {
    let id: UUID
    var lightId: UUID            // references SavedLight.id
    var lightName: String        // display name snapshot
    var unicastAddress: UInt16   // cached for execution
    var fromState: CueState      // position A (start)
    var toState: CueState        // position B (end)

    init(id: UUID = UUID(), lightId: UUID, lightName: String, unicastAddress: UInt16,
         fromState: CueState = CueState(), toState: CueState = CueState()) {
        self.id = id
        self.lightId = lightId
        self.lightName = lightName
        self.unicastAddress = unicastAddress
        self.fromState = fromState
        self.toState = toState
    }
}

// MARK: - Cue State (snapshot of a light's look)

struct CueState: Codable {
    var isOn: Bool = true
    var mode: String = "CCT"           // LightMode.rawValue
    var intensity: Double = 50.0

    // CCT
    var cctKelvin: Double = 5600.0

    // HSI
    var hue: Double = 0.0
    var saturation: Double = 100.0
    var hsiIntensity: Double = 50.0
    var hsiCCT: Double = 5600.0

    // Effects
    var effectId: Int = 0
    var effectSpeed: Double = 50.0
    var effectFrequency: Double = 8.0
    var copCarColor: Int = 0

    // Faulty Bulb
    var faultyBulbMin: Double = 20.0
    var faultyBulbMax: Double = 100.0
    var faultyBulbTransition: Double = 0.0
    var faultyBulbPoints: Double = 2.0
    var faultyBulbFrequency: Double = 5.0
    var faultyBulbBias: Double = 100.0
    var faultyBulbInverse: Double = 0.0
    var faultyBulbRecovery: Double = 100.0
    var faultyBulbWarmth: Double = 0.0
    var faultyBulbColorMode: String = "CCT"

    // Pulsing
    var pulsingMin: Double = 0.0
    var pulsingMax: Double = 100.0
    var pulsingShape: Double = 50.0

    // Color modes
    var paparazziColorMode: String = "CCT"
    var strobeHz: Double = 4.0
    var strobeColorMode: String = "CCT"
    var effectColorMode: String = "CCT"

    // Party
    var partyColors: [Double] = [0, 60, 120, 180, 240, 300]
    var partyTransition: Double = 50.0
    var partyHueBias: Double = 0.0

    // MARK: - Capture from LightState

    static func from(_ ls: LightState) -> CueState {
        CueState(
            isOn: ls.isOn,
            mode: ls.mode.rawValue,
            intensity: ls.intensity,
            cctKelvin: ls.cctKelvin,
            hue: ls.hue,
            saturation: ls.saturation,
            hsiIntensity: ls.hsiIntensity,
            hsiCCT: ls.hsiCCT,
            effectId: ls.selectedEffect.rawValue,
            effectSpeed: ls.effectSpeed,
            effectFrequency: ls.effectFrequency,
            copCarColor: ls.copCarColor,
            faultyBulbMin: ls.faultyBulbMin,
            faultyBulbMax: ls.faultyBulbMax,
            faultyBulbTransition: ls.faultyBulbTransition,
            faultyBulbPoints: ls.faultyBulbPoints,
            faultyBulbFrequency: ls.faultyBulbFrequency,
            faultyBulbBias: ls.faultyBulbBias,
            faultyBulbInverse: ls.faultyBulbInverse,
            faultyBulbRecovery: ls.faultyBulbRecovery,
            faultyBulbWarmth: ls.faultyBulbWarmth,
            faultyBulbColorMode: ls.faultyBulbColorMode.rawValue,
            pulsingMin: ls.pulsingMin,
            pulsingMax: ls.pulsingMax,
            pulsingShape: ls.pulsingShape,
            paparazziColorMode: ls.paparazziColorMode.rawValue,
            strobeHz: ls.strobeHz,
            strobeColorMode: ls.strobeColorMode.rawValue,
            effectColorMode: ls.effectColorMode.rawValue,
            partyColors: ls.partyColors,
            partyTransition: ls.partyTransition,
            partyHueBias: ls.partyHueBias
        )
    }

    // MARK: - Apply to LightState

    func apply(to ls: LightState) {
        ls.isOn = isOn
        ls.mode = LightMode(rawValue: mode) ?? .cct
        ls.intensity = intensity
        ls.cctKelvin = cctKelvin
        ls.hue = hue
        ls.saturation = saturation
        ls.hsiIntensity = hsiIntensity
        ls.hsiCCT = hsiCCT
        ls.selectedEffect = LightEffect(rawValue: effectId) ?? .none
        ls.effectSpeed = effectSpeed
        ls.effectFrequency = effectFrequency
        ls.copCarColor = copCarColor
        ls.faultyBulbMin = faultyBulbMin
        ls.faultyBulbMax = faultyBulbMax
        ls.faultyBulbTransition = faultyBulbTransition
        ls.faultyBulbPoints = faultyBulbPoints
        ls.faultyBulbFrequency = faultyBulbFrequency
        ls.faultyBulbBias = faultyBulbBias
        ls.faultyBulbInverse = faultyBulbInverse
        ls.faultyBulbRecovery = faultyBulbRecovery
        ls.faultyBulbWarmth = faultyBulbWarmth
        ls.faultyBulbColorMode = LightMode(rawValue: faultyBulbColorMode) ?? .cct
        ls.pulsingMin = pulsingMin
        ls.pulsingMax = pulsingMax
        ls.pulsingShape = pulsingShape
        ls.paparazziColorMode = LightMode(rawValue: paparazziColorMode) ?? .cct
        ls.strobeHz = strobeHz
        ls.strobeColorMode = LightMode(rawValue: strobeColorMode) ?? .cct
        ls.effectColorMode = LightMode(rawValue: effectColorMode) ?? .cct
        ls.partyColors = partyColors
        ls.partyTransition = partyTransition
        ls.partyHueBias = partyHueBias
        ls.effectPlaying = false
    }

    // MARK: - Interpolation

    /// Linearly interpolate between two CueStates. t=0 returns `from`, t=1 returns `to`.
    static func interpolate(from a: CueState, to b: CueState, t: Double) -> CueState {
        let t = min(max(t, 0), 1)
        func lerp(_ start: Double, _ end: Double) -> Double {
            start + (end - start) * t
        }
        var result = b
        result.intensity = lerp(a.intensity, b.intensity)
        result.cctKelvin = lerp(a.cctKelvin, b.cctKelvin)
        result.hue = lerp(a.hue, b.hue)
        result.saturation = lerp(a.saturation, b.saturation)
        result.hsiIntensity = lerp(a.hsiIntensity, b.hsiIntensity)
        result.hsiCCT = lerp(a.hsiCCT, b.hsiCCT)
        return result
    }

    // MARK: - Summary

    var modeSummary: String {
        let m = LightMode(rawValue: mode) ?? .cct
        switch m {
        case .cct:
            return "CCT \(Int(cctKelvin))K @ \(Int(intensity))%"
        case .hsi:
            return "HSI H\(Int(hue)) S\(Int(saturation)) @ \(Int(intensity))%"
        case .effects:
            let effect = LightEffect(rawValue: effectId)
            return effect?.name ?? "FX"
        }
    }

    var shortSummary: String {
        let m = LightMode(rawValue: mode) ?? .cct
        switch m {
        case .cct:
            return "\(Int(intensity))% \(Int(cctKelvin))K"
        case .hsi:
            return "H\(Int(hue)) S\(Int(saturation))"
        case .effects:
            return LightEffect(rawValue: effectId)?.name ?? "FX"
        }
    }
}

// MARK: - Beat Mode Types

enum TimelineMode: String, Codable {
    case seconds
    case beats
}

struct TimeSignature: Codable, Equatable {
    var beatsPerBar: Int
    var beatUnit: Int

    var quarterNotesPerBar: Double {
        Double(beatsPerBar) * (4.0 / Double(beatUnit))
    }

    var displayString: String {
        "\(beatsPerBar)/\(beatUnit)"
    }

    static let common = TimeSignature(beatsPerBar: 4, beatUnit: 4)
}

struct TempoEvent: Identifiable, Codable, Equatable {
    let id: UUID
    var beatPosition: Double
    var bpm: Double
    var timeSignature: TimeSignature

    init(id: UUID = UUID(), beatPosition: Double = 0, bpm: Double = 120, timeSignature: TimeSignature = .common) {
        self.id = id
        self.beatPosition = beatPosition
        self.bpm = bpm
        self.timeSignature = timeSignature
    }
}

// MARK: - Timeline

struct Timeline: Identifiable, Codable {
    let id: UUID
    var name: String
    var tracks: [TimelineTrack]
    var totalDuration: Double
    var audioFileName: String?
    var audioFileId: String?

    var mode: TimelineMode?
    var totalBeats: Double?
    var tempoEvents: [TempoEvent]?
    var metronomeEnabled: Bool?

    var effectiveMode: TimelineMode { mode ?? .seconds }

    var effectiveTempoEvents: [TempoEvent] {
        guard let events = tempoEvents, !events.isEmpty else {
            return [TempoEvent()]
        }
        return events.sorted { $0.beatPosition < $1.beatPosition }
    }

    init(id: UUID = UUID(), name: String = "New Timeline", tracks: [TimelineTrack] = [], totalDuration: Double = 30,
         audioFileName: String? = nil, audioFileId: String? = nil,
         mode: TimelineMode? = nil, totalBeats: Double? = nil,
         tempoEvents: [TempoEvent]? = nil, metronomeEnabled: Bool? = nil) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.totalDuration = totalDuration
        self.audioFileName = audioFileName
        self.audioFileId = audioFileId
        self.mode = mode
        self.totalBeats = totalBeats
        self.tempoEvents = tempoEvents
        self.metronomeEnabled = metronomeEnabled
    }
}

struct TimelineTrack: Identifiable, Codable {
    let id: UUID
    var lightId: UUID
    var lightName: String
    var unicastAddress: UInt16
    var blocks: [TimelineBlock]

    init(id: UUID = UUID(), lightId: UUID, lightName: String, unicastAddress: UInt16, blocks: [TimelineBlock] = []) {
        self.id = id
        self.lightId = lightId
        self.lightName = lightName
        self.unicastAddress = unicastAddress
        self.blocks = blocks
    }
}

struct TimelineBlock: Identifiable, Codable {
    let id: UUID
    var startTime: Double
    var duration: Double
    var state: CueState

    init(id: UUID = UUID(), startTime: Double = 0, duration: Double = 2, state: CueState = CueState()) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.state = state
    }
}
