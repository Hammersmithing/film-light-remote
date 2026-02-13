import SwiftUI

struct LightControlView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState
    var cctRange: ClosedRange<Double> = 2700...6500
    var intensityStep: Double = 1.0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Power and Intensity
                PowerIntensitySection(lightState: lightState, intensityStep: intensityStep)

                // Mode picker
                ModePicker(selectedMode: $lightState.mode)
                    .allowsHitTesting(lightState.isOn)
                    .opacity(lightState.isOn ? 1.0 : 0.4)

                // Mode-specific controls
                Group {
                    switch lightState.mode {
                    case .cct:
                        CCTControls(lightState: lightState, cctRange: cctRange)
                    case .hsi:
                        HSIControls(lightState: lightState)
                    case .rgbw:
                        RGBWControls(lightState: lightState)
                    case .effects:
                        EffectsControls(lightState: lightState)
                    }
                }
                .allowsHitTesting(lightState.isOn)
                .opacity(lightState.isOn ? 1.0 : 0.4)

            }
            .padding()
        }
        .onReceive(bleManager.$lastLightStatus.compactMap { $0 }) { status in
            lightState.applyStatus(status)
        }
    }
}

// MARK: - Throttled Sender

/// Throttles BLE command sends to avoid flooding the connection while dragging sliders.
private class ThrottledSender {
    private var lastSendTime: Date = .distantPast
    private var pendingWork: DispatchWorkItem?
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    func send(_ action: @escaping () -> Void) {
        pendingWork?.cancel()
        let now = Date()
        if now.timeIntervalSince(lastSendTime) >= interval {
            lastSendTime = now
            action()
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.lastSendTime = Date()
                action()
            }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
        }
    }
}

// MARK: - Intensity Slider (2D: horizontal = coarse, vertical = fine)

private struct IntensitySlider: View {
    @Binding var value: Double
    var fineStep: Double = 0.1
    var onChanged: () -> Void

    @State private var dragStartValue: Double = 0
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let fraction = value / 100.0

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray4))
                    .frame(height: 6)

                // Fill
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.orange)
                    .frame(width: max(0, trackWidth * fraction), height: 6)

                // Thumb
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: 28, height: 28)
                    .offset(x: fraction * (trackWidth - 28))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            dragStartValue = value
                            isDragging = true
                        }

                        // Horizontal: coarse — whole number steps
                        let hPct = drag.translation.width / trackWidth * 100
                        let coarse = round(hPct)

                        // Vertical: fine — 0.1 steps, up = increase
                        let fine = round(-drag.translation.height / 10) * fineStep

                        let newValue = max(0, min(100, dragStartValue + coarse + fine))
                        value = newValue
                        onChanged()
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 28)
    }
}

// MARK: - Power and Intensity Section
struct PowerIntensitySection: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState
    var intensityStep: Double = 1.0
    private let throttle = ThrottledSender()

    var body: some View {
        VStack(spacing: 16) {
            // Power toggle with intensity display
            HStack {
                Button {
                    lightState.isOn.toggle()
                    bleManager.setPowerOn(lightState.isOn)
                } label: {
                    Image(systemName: lightState.isOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 44))
                        .foregroundColor(lightState.isOn ? .green : .gray)
                }

                Spacer()

                // Intensity percentage display
                Text(intensityStep < 1 ? String(format: "%.1f%%", lightState.intensity) : "\(Int(lightState.intensity))%")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            // Intensity slider — horizontal = whole numbers, vertical = 0.1 fine tune
            VStack(alignment: .leading, spacing: 4) {
                Text("Intensity")
                    .font(.caption)
                    .foregroundColor(.secondary)

                IntensitySlider(value: $lightState.intensity, fineStep: intensityStep) {
                    throttle.send { [bleManager, lightState] in
                        switch lightState.mode {
                        case .hsi:
                            lightState.hsiIntensity = lightState.intensity
                            bleManager.setHSI(hue: Int(lightState.hue),
                                            saturation: Int(lightState.saturation),
                                            intensity: Int(lightState.intensity))
                        default:
                            bleManager.setIntensity(lightState.intensity)
                        }
                    }
                }
                .allowsHitTesting(lightState.isOn)
                .opacity(lightState.isOn ? 1.0 : 0.4)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Mode Picker
struct ModePicker: View {
    @Binding var selectedMode: LightMode

    var body: some View {
        Picker("Mode", selection: $selectedMode) {
            ForEach(LightMode.allCases) { mode in
                Label(mode.rawValue, systemImage: mode.icon)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - CCT Controls
struct CCTControls: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState
    var cctRange: ClosedRange<Double> = 2700...6500
    private let throttle = ThrottledSender()

    var body: some View {
        VStack(spacing: 16) {
            // Color preview
            RoundedRectangle(cornerRadius: 8)
                .fill(lightState.cctColor)
                .frame(height: 60)
                .overlay(
                    Text("\(Int(lightState.cctKelvin))K")
                        .font(.headline)
                        .foregroundColor(.black.opacity(0.7))
                )

            // CCT slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Color Temperature")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(lightState.cctKelvin))K")
                        .font(.caption)
                        .monospacedDigit()
                }

                // Gradient background for CCT slider
                ZStack(alignment: .leading) {
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.7, blue: 0.4),
                            Color.white,
                            Color(red: 0.8, green: 0.9, blue: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 8)
                    .cornerRadius(4)

                    Slider(value: $lightState.cctKelvin, in: cctRange, step: 100)
                        .tint(.clear)
                        .onChange(of: lightState.cctKelvin) { _ in
                            throttle.send { [bleManager, lightState] in
                                bleManager.setCCT(Int(lightState.cctKelvin))
                            }
                        }
                }
            }

        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - HSI Controls
struct HSIControls: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState
    private let throttle = ThrottledSender()

    var body: some View {
        VStack(spacing: 16) {
            // Color preview
            RoundedRectangle(cornerRadius: 8)
                .fill(lightState.hsiColor)
                .frame(height: 60)

            // Hue slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Hue")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(lightState.hue))")
                        .font(.caption)
                        .monospacedDigit()
                }

                ZStack {
                    LinearGradient(
                        colors: (0...6).map { Color(hue: Double($0) / 6.0, saturation: 1.0, brightness: 1.0) },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 8)
                    .cornerRadius(4)

                    Slider(value: $lightState.hue, in: 0...360, step: 1)
                        .tint(.clear)
                        .onChange(of: lightState.hue) { _ in
                            sendHSI()
                        }
                }
            }

            // Saturation slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Saturation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(lightState.saturation))%")
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(value: $lightState.saturation, in: 0...100, step: 1)
                    .onChange(of: lightState.saturation) { _ in
                        sendHSI()
                    }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func sendHSI() {
        throttle.send { [bleManager, lightState] in
            bleManager.setHSI(hue: Int(lightState.hue),
                            saturation: Int(lightState.saturation),
                            intensity: Int(lightState.hsiIntensity))
        }
    }
}

// MARK: - RGBW Controls
struct RGBWControls: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState

    var body: some View {
        VStack(spacing: 16) {
            // Color preview
            RoundedRectangle(cornerRadius: 8)
                .fill(lightState.rgbColor)
                .frame(height: 60)

            // RGB sliders
            ColorSlider(label: "Red", value: $lightState.red, color: .red) {
                sendRGB()
            }
            ColorSlider(label: "Green", value: $lightState.green, color: .green) {
                sendRGB()
            }
            ColorSlider(label: "Blue", value: $lightState.blue, color: .blue) {
                sendRGB()
            }
            ColorSlider(label: "White", value: $lightState.white, color: .gray) {
                sendRGB()
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func sendRGB() {
        bleManager.setRGB(red: Int(lightState.red),
                         green: Int(lightState.green),
                         blue: Int(lightState.blue))
    }
}

struct ColorSlider: View {
    let label: String
    @Binding var value: Double
    let color: Color
    let onChanged: () -> Void
    private let throttle = ThrottledSender()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(value))")
                    .font(.caption)
                    .monospacedDigit()
            }

            Slider(value: $value, in: 0...255, step: 1)
                .tint(color)
                .onChange(of: value) { _ in
                    throttle.send {
                        onChanged()
                    }
                }
        }
    }
}

// MARK: - Effects Controls
struct EffectsControls: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState
    private let throttle = ThrottledSender()

    let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        VStack(spacing: 16) {
            // Effects grid
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(LightEffect.allCases) { effect in
                    Button {
                        lightState.selectedEffect = effect
                        bleManager.setEffect(effect.rawValue, speed: Int(lightState.effectSpeed))
                    } label: {
                        Text(effect.name)
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                lightState.selectedEffect == effect
                                    ? Color.accentColor
                                    : Color(.systemGray5)
                            )
                            .foregroundColor(
                                lightState.selectedEffect == effect
                                    ? .white
                                    : .primary
                            )
                            .cornerRadius(8)
                    }
                }
            }

            // Speed slider
            if lightState.selectedEffect != .none {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Speed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(lightState.effectSpeed))%")
                            .font(.caption)
                            .monospacedDigit()
                    }

                    Slider(value: $lightState.effectSpeed, in: 0...100, step: 1)
                        .onChange(of: lightState.effectSpeed) { _ in
                            throttle.send { [bleManager, lightState] in
                                bleManager.setEffect(lightState.selectedEffect.rawValue,
                                                   speed: Int(lightState.effectSpeed))
                            }
                        }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Presets Section
struct PresetsSection: View {
    @ObservedObject var lightState: LightState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Presets")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(LightPreset.defaults) { preset in
                        Button {
                            lightState.applyPreset(preset)
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(presetColor(preset))
                                    .frame(width: 40, height: 40)

                                Text(preset.name)
                                    .font(.caption2)
                                    .foregroundColor(.primary)
                            }
                            .frame(width: 60)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func presetColor(_ preset: LightPreset) -> Color {
        switch preset.mode {
        case .cct:
            return kelvinToColor(preset.cctKelvin ?? 5600)
        case .hsi:
            return Color(hue: (preset.hue ?? 0) / 360.0,
                        saturation: (preset.saturation ?? 100) / 100.0,
                        brightness: 1.0)
        case .rgbw:
            return Color(red: (preset.red ?? 255) / 255.0,
                        green: (preset.green ?? 255) / 255.0,
                        blue: (preset.blue ?? 255) / 255.0)
        case .effects:
            return .purple
        }
    }

    private func kelvinToColor(_ kelvin: Double) -> Color {
        let temp = kelvin / 100.0
        var r, g, b: Double

        if temp <= 66 {
            r = 255
            g = max(0, 99.4708025861 * log(temp) - 161.1195681661)
            b = temp <= 19 ? 0 : max(0, 138.5177312231 * log(temp - 10) - 305.0447927307)
        } else {
            r = max(0, 329.698727446 * pow(temp - 60, -0.1332047592))
            g = max(0, 288.1221695283 * pow(temp - 60, -0.0755148492))
            b = 255
        }

        return Color(red: min(r, 255) / 255.0,
                    green: min(g, 255) / 255.0,
                    blue: min(b, 255) / 255.0)
    }
}

#Preview {
    LightControlView(lightState: LightState())
        .environmentObject(BLEManager())
}
