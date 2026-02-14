import Foundation
import SwiftUI

// MARK: - Light Mode
enum LightMode: String, CaseIterable, Identifiable {
    case cct = "CCT"
    case hsi = "HSI"
    case effects = "FX"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cct: return "thermometer"
        case .hsi: return "paintpalette"
        case .effects: return "sparkles"
        }
    }
}

// MARK: - Light Effect
/// Raw values match the Sidus protocol effectType IDs
enum LightEffect: Int, CaseIterable, Identifiable {
    case none = 0
    case paparazzi = 1
    case lightning = 2
    case tvFlicker = 3
    case candle = 4
    case fire = 5
    case strobe = 6
    case explosion = 7
    case faultyBulb = 8
    case pulsing = 9
    case welding = 10
    case copCar = 11
    case party = 13
    case fireworks = 14

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .none: return "None"
        case .paparazzi: return "Paparazzi"
        case .lightning: return "Lightning"
        case .tvFlicker: return "TV Flicker"
        case .candle: return "Candle"
        case .fire: return "Fire"
        case .strobe: return "Strobe"
        case .explosion: return "Explosion"
        case .faultyBulb: return "Faulty Bulb"
        case .pulsing: return "Pulsing"
        case .welding: return "Welding"
        case .copCar: return "Cop Car"
        case .party: return "Party"
        case .fireworks: return "Fireworks"
        }
    }

    var icon: String {
        switch self {
        case .none: return "xmark.circle"
        case .paparazzi: return "camera.fill"
        case .lightning: return "bolt.fill"
        case .tvFlicker: return "tv"
        case .candle: return "flame"
        case .fire: return "flame.fill"
        case .strobe: return "light.max"
        case .explosion: return "burst.fill"
        case .faultyBulb: return "lightbulb"
        case .pulsing: return "waveform"
        case .welding: return "sparkle"
        case .copCar: return "light.beacon.max"
        case .party: return "party.popper"
        case .fireworks: return "fireworks"
        }
    }

    /// Effects available on the Amaran 660c (excludes .none)
    static var availableEffects: [LightEffect] {
        allCases.filter { $0 != .none }
    }
}

// MARK: - Light State
class LightState: ObservableObject {
    // Power
    @Published var isOn: Bool = true

    // Current mode
    @Published var mode: LightMode = .cct

    // Intensity (0-100%)
    @Published var intensity: Double = 50.0

    // CCT Mode (2700K - 6500K typical, Storm 80c may differ)
    @Published var cctKelvin: Double = 5600.0

    // HSI Mode
    @Published var hue: Double = 0.0          // 0-360
    @Published var saturation: Double = 100.0 // 0-100
    @Published var hsiIntensity: Double = 50.0
    @Published var hsiCCT: Double = 5600.0    // White balance in Kelvin (2000-10000)

    // RGBW Mode (0-255 each)
    @Published var red: Double = 255.0
    @Published var green: Double = 255.0
    @Published var blue: Double = 255.0
    @Published var white: Double = 0.0

    // Effects
    @Published var selectedEffect: LightEffect = .none
    @Published var effectSpeed: Double = 50.0 // 0-100
    @Published var effectFrequency: Double = 8.0 // 0-15 (protocol frq field)
    @Published var copCarColor: Int = 0 // 0=Red, 1=Blue, 2=R+B, 3=B+W, 4=R+B+W
    @Published var faultyBulbMin: Double = 20.0 // 0-100%
    @Published var faultyBulbMax: Double = 100.0 // 0-100%
    @Published var faultyBulbTransition: Double = 0.0 // 0=instant click, 15=slow fade

    // MARK: - Computed Properties

    var hsiColor: Color {
        Color(hue: hue / 360.0, saturation: saturation / 100.0, brightness: 1.0)
    }

    var rgbColor: Color {
        Color(red: red / 255.0, green: green / 255.0, blue: blue / 255.0)
    }

    var cctColor: Color {
        // Approximate CCT to RGB for preview
        kelvinToColor(cctKelvin)
    }

    // MARK: - CCT to Color Approximation

    private func kelvinToColor(_ kelvin: Double) -> Color {
        // Approximate color temperature visualization
        let temp = kelvin / 100.0
        var r, g, b: Double

        if temp <= 66 {
            r = 255
            g = temp
            g = 99.4708025861 * log(g) - 161.1195681661
            if temp <= 19 {
                b = 0
            } else {
                b = temp - 10
                b = 138.5177312231 * log(b) - 305.0447927307
            }
        } else {
            r = temp - 60
            r = 329.698727446 * pow(r, -0.1332047592)
            g = temp - 60
            g = 288.1221695283 * pow(g, -0.0755148492)
            b = 255
        }

        r = max(0, min(255, r))
        g = max(0, min(255, g))
        b = max(0, min(255, b))

        return Color(red: r / 255.0, green: g / 255.0, blue: b / 255.0)
    }

    // MARK: - Apply Hardware Status

    /// Update state from a parsed Sidus status (received from the light hardware)
    func applyStatus(_ status: SidusLightStatus) {
        isOn = status.isOn

        switch status.commandType {
        case 2: // CCT
            mode = .cct
            intensity = status.intensity
            if let kelvin = status.cctKelvin {
                cctKelvin = Double(kelvin)
            }
        case 1: // HSI
            mode = .hsi
            intensity = status.intensity
            hsiIntensity = status.intensity
            if let h = status.hue {
                hue = Double(h)
            }
            if let s = status.saturation {
                saturation = Double(s)
            }
        case 12: // Sleep/power only
            break
        default:
            break
        }
    }

    // MARK: - Persistence

    private static let statePrefix = "lightState."

    func save(forLightId id: UUID) {
        let data = PersistedState(
            isOn: isOn, mode: mode.rawValue, intensity: intensity,
            cctKelvin: cctKelvin, hue: hue, saturation: saturation,
            hsiIntensity: hsiIntensity, hsiCCT: hsiCCT, red: red, green: green,
            blue: blue, white: white,
            effectId: selectedEffect.rawValue, effectSpeed: effectSpeed
        )
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: Self.statePrefix + id.uuidString)
        }
    }

    func load(forLightId id: UUID) {
        guard let data = UserDefaults.standard.data(forKey: Self.statePrefix + id.uuidString),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        isOn = state.isOn
        mode = LightMode(rawValue: state.mode) ?? .cct
        intensity = state.intensity
        cctKelvin = state.cctKelvin
        hue = state.hue
        saturation = state.saturation
        hsiIntensity = state.hsiIntensity
        hsiCCT = state.hsiCCT ?? 5600.0
        red = state.red
        green = state.green
        blue = state.blue
        white = state.white
        selectedEffect = LightEffect(rawValue: state.effectId) ?? .none
        effectSpeed = state.effectSpeed
    }

    private struct PersistedState: Codable {
        var isOn: Bool
        var mode: String
        var intensity: Double
        var cctKelvin: Double
        var hue: Double
        var saturation: Double
        var hsiIntensity: Double
        var hsiCCT: Double?
        var red: Double
        var green: Double
        var blue: Double
        var white: Double
        var effectId: Int
        var effectSpeed: Double
    }

    // MARK: - Presets

    func applyPreset(_ preset: LightPreset) {
        mode = preset.mode
        intensity = preset.intensity

        switch preset.mode {
        case .cct:
            cctKelvin = preset.cctKelvin ?? 5600
        case .hsi:
            hue = preset.hue ?? 0
            saturation = preset.saturation ?? 100
        case .effects:
            if let eid = preset.effectId {
                selectedEffect = LightEffect(rawValue: eid) ?? .none
            }
        }
    }
}

// MARK: - Light Preset
struct LightPreset: Identifiable, Codable {
    let id: UUID
    var name: String
    var mode: LightMode
    var intensity: Double

    // CCT
    var cctKelvin: Double?

    // HSI
    var hue: Double?
    var saturation: Double?

    // RGBW
    var red: Double?
    var green: Double?
    var blue: Double?
    var white: Double?

    // Effects
    var effectId: Int?
    var effectSpeed: Double?

    var effect: LightEffect? {
        guard let id = effectId else { return nil }
        return LightEffect(rawValue: id)
    }

    // Codable conformance for LightMode
    enum CodingKeys: String, CodingKey {
        case id, name, modeRaw = "mode", intensity
        case cctKelvin, hue, saturation
        case red, green, blue, white
        case effectId, effectSpeed
    }

    init(id: UUID = UUID(), name: String, mode: LightMode, intensity: Double,
         cctKelvin: Double? = nil, hue: Double? = nil, saturation: Double? = nil,
         red: Double? = nil, green: Double? = nil, blue: Double? = nil, white: Double? = nil,
         effectId: Int? = nil, effectSpeed: Double? = nil) {
        self.id = id
        self.name = name
        self.mode = mode
        self.intensity = intensity
        self.cctKelvin = cctKelvin
        self.hue = hue
        self.saturation = saturation
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
        self.effectId = effectId
        self.effectSpeed = effectSpeed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let modeRaw = try container.decode(String.self, forKey: .modeRaw)
        mode = LightMode(rawValue: modeRaw) ?? .cct
        intensity = try container.decode(Double.self, forKey: .intensity)
        cctKelvin = try container.decodeIfPresent(Double.self, forKey: .cctKelvin)
        hue = try container.decodeIfPresent(Double.self, forKey: .hue)
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation)
        red = try container.decodeIfPresent(Double.self, forKey: .red)
        green = try container.decodeIfPresent(Double.self, forKey: .green)
        blue = try container.decodeIfPresent(Double.self, forKey: .blue)
        white = try container.decodeIfPresent(Double.self, forKey: .white)
        effectId = try container.decodeIfPresent(Int.self, forKey: .effectId)
        effectSpeed = try container.decodeIfPresent(Double.self, forKey: .effectSpeed)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mode.rawValue, forKey: .modeRaw)
        try container.encode(intensity, forKey: .intensity)
        try container.encodeIfPresent(cctKelvin, forKey: .cctKelvin)
        try container.encodeIfPresent(hue, forKey: .hue)
        try container.encodeIfPresent(saturation, forKey: .saturation)
        try container.encodeIfPresent(red, forKey: .red)
        try container.encodeIfPresent(green, forKey: .green)
        try container.encodeIfPresent(blue, forKey: .blue)
        try container.encodeIfPresent(white, forKey: .white)
        try container.encodeIfPresent(effectId, forKey: .effectId)
        try container.encodeIfPresent(effectSpeed, forKey: .effectSpeed)
    }
}

// MARK: - Default Presets
extension LightPreset {
    static let defaults: [LightPreset] = [
        LightPreset(name: "Daylight", mode: .cct, intensity: 100, cctKelvin: 5600),
        LightPreset(name: "Tungsten", mode: .cct, intensity: 100, cctKelvin: 3200),
        LightPreset(name: "Cool White", mode: .cct, intensity: 80, cctKelvin: 6500),
        LightPreset(name: "Warm White", mode: .cct, intensity: 80, cctKelvin: 2700),
        LightPreset(name: "Red", mode: .hsi, intensity: 100, hue: 0, saturation: 100),
        LightPreset(name: "Green", mode: .hsi, intensity: 100, hue: 120, saturation: 100),
        LightPreset(name: "Blue", mode: .hsi, intensity: 100, hue: 240, saturation: 100),
        LightPreset(name: "Amber", mode: .hsi, intensity: 100, hue: 30, saturation: 100),
    ]
}
