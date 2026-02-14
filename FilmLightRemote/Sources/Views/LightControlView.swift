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
                    .onChange(of: lightState.mode) { newMode in
                        // Stop any active effect when switching away from FX
                        if newMode != .effects && lightState.selectedEffect != .none {
                            lightState.selectedEffect = .none
                            bleManager.stopEffect()
                        }
                    }

                // Mode-specific controls
                Group {
                    switch lightState.mode {
                    case .cct:
                        CCTControls(lightState: lightState, cctRange: cctRange)
                    case .hsi:
                        HSIControls(lightState: lightState)
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
                        case .effects:
                            if lightState.selectedEffect != .none {
                                bleManager.setEffect(
                                    effectType: lightState.selectedEffect.rawValue,
                                    intensityPercent: lightState.intensity,
                                    frq: Int(lightState.effectFrequency))
                            }
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

// MARK: - Effects Controls
struct EffectsControls: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState
    private let throttle = ThrottledSender()

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        VStack(spacing: 16) {
            // Effect buttons grid
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(LightEffect.availableEffects) { effect in
                    Button {
                        if lightState.selectedEffect == effect {
                            // Tap active effect to turn it off
                            lightState.selectedEffect = .none
                            bleManager.stopEffect()
                        } else {
                            lightState.selectedEffect = effect
                            bleManager.setEffect(
                                effectType: effect.rawValue,
                                intensityPercent: lightState.intensity,
                                frq: Int(lightState.effectFrequency))
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: effect.icon)
                                .font(.system(size: 24))
                            Text(effect.name)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            lightState.selectedEffect == effect
                                ? Color.orange.opacity(0.3)
                                : Color(.systemGray5)
                        )
                        .foregroundColor(
                            lightState.selectedEffect == effect
                                ? .orange
                                : .primary
                        )
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(lightState.selectedEffect == effect ? Color.orange : Color.clear, lineWidth: 2)
                        )
                    }
                }
            }

            // Frequency slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Frequency")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(lightState.effectFrequency))")
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(value: $lightState.effectFrequency, in: 0...15, step: 1)
                    .onChange(of: lightState.effectFrequency) { _ in
                        guard lightState.selectedEffect != .none else { return }
                        throttle.send { [bleManager, lightState] in
                            bleManager.setEffect(
                                effectType: lightState.selectedEffect.rawValue,
                                intensityPercent: lightState.intensity,
                                frq: Int(lightState.effectFrequency))
                        }
                    }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

#Preview {
    LightControlView(lightState: LightState())
        .environmentObject(BLEManager())
}
