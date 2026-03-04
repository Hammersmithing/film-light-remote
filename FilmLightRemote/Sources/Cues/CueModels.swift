import Foundation

// MARK: - Cue List

struct CueList: Identifiable, Codable {
    let id: UUID
    var name: String
    var cues: [Cue]

    init(id: UUID = UUID(), name: String = "New Cue List", cues: [Cue] = []) {
        self.id = id
        self.name = name
        self.cues = cues
    }
}

// MARK: - Cue

struct Cue: Identifiable, Codable {
    let id: UUID
    var name: String
    var lightEntries: [LightCueEntry]
    var fadeTime: Double         // duration in seconds (0 = snap)
    var autoFollow: Bool         // start when previous cue ends
    var followDelay: Double      // delay before this cue fires (seconds)

    init(id: UUID = UUID(), name: String = "Cue", lightEntries: [LightCueEntry] = [],
         fadeTime: Double = 0, autoFollow: Bool = false, followDelay: Double = 0) {
        self.id = id
        self.name = name
        self.lightEntries = lightEntries
        self.fadeTime = fadeTime
        self.autoFollow = autoFollow
        self.followDelay = followDelay
    }

    // Migrate old data: followDelay used to default to 1.0, now defaults to 0
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lightEntries = try c.decode([LightCueEntry].self, forKey: .lightEntries)
        fadeTime = try c.decode(Double.self, forKey: .fadeTime)
        autoFollow = try c.decode(Bool.self, forKey: .autoFollow)
        let rawDelay = try c.decode(Double.self, forKey: .followDelay)
        // Old default was 1.0 — reset to 0 unless autoFollow is on
        followDelay = (!autoFollow && rawDelay == 1.0) ? 0 : rawDelay
    }
}

// MARK: - Light Cue Entry

struct LightCueEntry: Identifiable, Codable {
    let id: UUID
    var lightId: UUID            // references SavedLight.id
    var lightName: String        // display name snapshot
    var unicastAddress: UInt16   // cached for cue execution
    var state: CueState

    init(id: UUID = UUID(), lightId: UUID, lightName: String, unicastAddress: UInt16, state: CueState = CueState()) {
        self.id = id
        self.lightId = lightId
        self.lightName = lightName
        self.unicastAddress = unicastAddress
        self.state = state
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
            return "H\(Int(hue)) \(Int(intensity))%"
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

    /// Quarter notes per bar (e.g. 4/4 → 4, 3/4 → 3, 6/8 → 3)
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
    var beatPosition: Double   // quarter notes from timeline start
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

    // Beat mode fields (all optional for backward compat)
    var mode: TimelineMode?
    var totalBeats: Double?
    var tempoEvents: [TempoEvent]?
    var metronomeEnabled: Bool?

    var effectiveMode: TimelineMode { mode ?? .seconds }

    var effectiveTempoEvents: [TempoEvent] {
        guard let events = tempoEvents, !events.isEmpty else {
            return [TempoEvent()]  // default 120 BPM 4/4
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
