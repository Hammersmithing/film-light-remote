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
                            if lightState.effectPlaying {
                                lightState.effectPlaying = false
                                bleManager.stopEffect()
                            }
                            lightState.selectedEffect = .none
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
                        EffectsControls(lightState: lightState, cctRange: cctRange)
                    }
                }
                .allowsHitTesting(lightState.isOn)
                .opacity(lightState.isOn ? 1.0 : 0.4)

            }
            .padding()
        }
        .onAppear { lightState.warmestCCT = cctRange.lowerBound }
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

    /// Tracks whether the effect was playing before the user turned the light off,
    /// so we can resume it when they turn it back on.
    @State private var effectWasPlaying = false

    var body: some View {
        VStack(spacing: 16) {
            // Power toggle with intensity display
            HStack {
                Button {
                    lightState.isOn.toggle()
                    if lightState.mode == .effects {
                        if !lightState.isOn {
                            // Turning off — remember if effect was playing, then pause
                            effectWasPlaying = lightState.effectPlaying
                            if lightState.effectPlaying {
                                lightState.effectPlaying = false
                                if lightState.selectedEffect == .faultyBulb {
                                    bleManager.stopFaultyBulb()
                                } else {
                                    bleManager.stopEffect()
                                }
                            }
                        } else {
                            // Turning on — resume effect if it was playing before
                            if effectWasPlaying {
                                lightState.effectPlaying = true
                                if lightState.selectedEffect == .faultyBulb {
                                    bleManager.startFaultyBulb(lightState: lightState)
                                } else if lightState.selectedEffect == .paparazzi && lightState.paparazziColorMode == .hsi {
                                    bleManager.startPaparazzi(lightState: lightState)
                                } else if lightState.selectedEffect != .none && lightState.selectedEffect != .copCar && lightState.effectColorMode == .hsi {
                                    bleManager.startSoftwareEffect(lightState: lightState)
                                } else if lightState.selectedEffect != .none {
                                    bleManager.setEffect(
                                        effectType: lightState.selectedEffect.rawValue,
                                        intensityPercent: lightState.intensity,
                                        frq: Int(lightState.effectFrequency),
                                        cctKelvin: Int(lightState.cctKelvin),
                                        copCarColor: lightState.copCarColor,
                                        effectMode: 0,
                                        hue: Int(lightState.hue),
                                        saturation: Int(lightState.saturation))
                                }
                            }
                        }
                    }
                    bleManager.setPowerOn(lightState.isOn)
                } label: {
                    Image(systemName: lightState.isOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 44))
                        .foregroundColor(lightState.isOn ? .green : .gray)
                }

                Spacer()

                if lightState.mode != .effects {
                    // Intensity percentage display
                    Text(intensityStep < 1 ? String(format: "%.1f%%", lightState.intensity) : "\(Int(lightState.intensity))%")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }

            if lightState.mode != .effects {
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
    var cctRange: ClosedRange<Double> = 2700...6500
    private let throttle = ThrottledSender()

    private let columnsPerRow = 3

    private var effectRows: [[LightEffect]] {
        let effects = LightEffect.availableEffects
        return stride(from: 0, to: effects.count, by: columnsPerRow).map {
            Array(effects[$0..<Swift.min($0 + columnsPerRow, effects.count)])
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(effectRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    ForEach(row) { effect in
                        EffectButton(
                            effect: effect,
                            isSelected: lightState.selectedEffect == effect
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if lightState.selectedEffect == effect {
                                    // Deselect — stop if playing
                                    stopCurrentEffect()
                                    lightState.effectPlaying = false
                                    lightState.selectedEffect = .none
                                } else {
                                    // Switch to new effect — stop previous, don't auto-play
                                    stopCurrentEffect()
                                    lightState.effectPlaying = false
                                    lightState.selectedEffect = effect
                                }
                            }
                        }
                    }
                    if row.count < columnsPerRow {
                        ForEach(0..<(columnsPerRow - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }

                if lightState.selectedEffect != .none,
                   row.contains(where: { $0 == lightState.selectedEffect }) {
                    EffectDetailPanel(
                        effect: lightState.selectedEffect,
                        lightState: lightState,
                        cctRange: cctRange,
                        onPlay: { playCurrentEffect() },
                        onStop: { stopCurrentEffect() },
                        onChanged: { if lightState.effectPlaying { sendCurrentEffect() } },
                        onModeChanged: { restartCurrentEffect() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    /// Whether the current effect needs a software engine (HSI on effects without native HSI)
    private var needsSoftwareEngine: Bool {
        guard currentEffectIsHSI else { return false }
        switch lightState.selectedEffect {
        case .faultyBulb: return false // has its own engine with HSI support
        case .copCar: return false     // uses its own color system
        default: return true
        }
    }

    /// Resolve the color mode for the current effect
    private var currentEffectIsHSI: Bool {
        switch lightState.selectedEffect {
        case .strobe: return lightState.strobeColorMode == .hsi
        case .paparazzi: return lightState.paparazziColorMode == .hsi
        default: return lightState.effectColorMode == .hsi
        }
    }

    private func playCurrentEffect() {
        guard lightState.selectedEffect != .none else { return }
        lightState.effectPlaying = true
        if lightState.selectedEffect == .faultyBulb {
            bleManager.startFaultyBulb(lightState: lightState)
        } else if needsSoftwareEngine {
            if lightState.selectedEffect == .paparazzi {
                bleManager.startPaparazzi(lightState: lightState)
            } else {
                bleManager.startSoftwareEffect(lightState: lightState)
            }
        } else {
            sendCurrentEffect()
        }
    }

    private func stopCurrentEffect() {
        guard lightState.effectPlaying else { return }
        lightState.effectPlaying = false
        if lightState.selectedEffect == .faultyBulb {
            bleManager.stopFaultyBulb()
        } else {
            bleManager.stopEffect()
        }
    }

    /// Called when the color mode picker changes while playing — restart with the right method.
    private func restartCurrentEffect() {
        guard lightState.effectPlaying else { return }
        bleManager.stopEffect()
        if needsSoftwareEngine {
            if lightState.selectedEffect == .paparazzi {
                bleManager.startPaparazzi(lightState: lightState)
            } else {
                bleManager.startSoftwareEffect(lightState: lightState)
            }
        } else {
            bleManager.setEffect(
                effectType: lightState.selectedEffect.rawValue,
                intensityPercent: lightState.intensity,
                frq: Int(lightState.effectFrequency),
                cctKelvin: Int(lightState.cctKelvin),
                copCarColor: lightState.copCarColor,
                effectMode: currentEffectIsHSI ? 1 : 0,
                hue: Int(lightState.hue),
                saturation: Int(lightState.saturation))
        }
    }

    /// Slider drag updates: update engine params or send hardware command.
    private func sendCurrentEffect() {
        guard lightState.selectedEffect != .none else { return }
        guard lightState.effectPlaying else { return }
        guard lightState.selectedEffect != .faultyBulb else { return }

        if needsSoftwareEngine {
            if lightState.selectedEffect == .paparazzi {
                bleManager.paparazziEngine?.updateParams(from: lightState)
            } else {
                bleManager.softwareEffectEngine?.updateParams(from: lightState)
            }
        } else {
            throttle.send { [bleManager, lightState] in
                bleManager.setEffect(
                    effectType: lightState.selectedEffect.rawValue,
                    intensityPercent: lightState.intensity,
                    frq: Int(lightState.effectFrequency),
                    cctKelvin: Int(lightState.cctKelvin),
                    copCarColor: lightState.copCarColor,
                    effectMode: 0,
                    hue: Int(lightState.hue),
                    saturation: Int(lightState.saturation))
            }
        }
    }
}

// MARK: - Effect Button
private struct EffectButton: View {
    let effect: LightEffect
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: effect.icon)
                    .font(.system(size: 24))
                Text(effect.name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? Color.orange.opacity(0.3) : Color(.systemGray5))
            .foregroundColor(isSelected ? .orange : .primary)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 2)
            )
        }
    }
}

// MARK: - Effect Detail Panel
private struct EffectDetailPanel: View {
    @EnvironmentObject var bleManager: BLEManager
    let effect: LightEffect
    @ObservedObject var lightState: LightState
    var cctRange: ClosedRange<Double> = 2700...6500
    var onPlay: () -> Void
    var onStop: () -> Void
    var onChanged: () -> Void
    var onModeChanged: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            // Play / Stop button
            Button {
                if lightState.effectPlaying {
                    onStop()
                } else {
                    onPlay()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: lightState.effectPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 16))
                    Text(lightState.effectPlaying ? "Stop" : "Play")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(lightState.effectPlaying ? Color.red.opacity(0.3) : Color.green.opacity(0.3))
                .foregroundColor(lightState.effectPlaying ? .red : .green)
                .cornerRadius(8)
            }

            switch effect {
            case .copCar:
                CopCarDetail(lightState: lightState, onChanged: onChanged)
            case .faultyBulb:
                FaultyBulbDetail(lightState: lightState, cctRange: cctRange)
            case .paparazzi:
                ColorModeEffectDetail(lightState: lightState, cctRange: cctRange, onChanged: onChanged, onModeChanged: onModeChanged, colorMode: $lightState.paparazziColorMode)
            case .strobe:
                ColorModeEffectDetail(lightState: lightState, cctRange: cctRange, onChanged: onChanged, onModeChanged: onModeChanged, colorMode: $lightState.strobeColorMode)
            case .pulsing:
                PulsingDetail(lightState: lightState, cctRange: cctRange, onChanged: onChanged, onModeChanged: onModeChanged)
            default:
                ColorModeEffectDetail(lightState: lightState, cctRange: cctRange, onChanged: onChanged, onModeChanged: onModeChanged, colorMode: $lightState.effectColorMode)
            }
        }
        .padding(12)
        .background(Color(.systemGray5))
        .cornerRadius(10)
    }
}

// MARK: - Frequency Slider (shared)
private struct FrequencySlider: View {
    @ObservedObject var lightState: LightState
    var onChanged: () -> Void
    private let throttle = ThrottledSender()

    var body: some View {
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
                    throttle.send { onChanged() }
                }
        }
    }
}

// MARK: - Range Slider (dual thumb)
private struct RangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double = 1

    @State private var isDraggingLow = false
    @State private var isDraggingHigh = false
    @State private var dragStartLow: Double = 0
    @State private var dragStartHigh: Double = 0

    private let thumbSize: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width - thumbSize
            let span = range.upperBound - range.lowerBound
            let lowFrac = span > 0 ? (low - range.lowerBound) / span : 0
            let highFrac = span > 0 ? (high - range.lowerBound) / span : 1

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color(.systemGray4))
                    .frame(height: 6)
                    .padding(.horizontal, thumbSize / 2)

                // Fill between thumbs
                Capsule()
                    .fill(Color.orange)
                    .frame(width: max(0, (highFrac - lowFrac) * trackWidth), height: 6)
                    .offset(x: thumbSize / 2 + lowFrac * trackWidth)

                // Low thumb
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: lowFrac * trackWidth)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                if !isDraggingLow {
                                    dragStartLow = low
                                    isDraggingLow = true
                                }
                                let pct = drag.translation.width / trackWidth * span
                                let raw = dragStartLow + pct
                                let clamped = max(range.lowerBound, min(high, raw))
                                low = (clamped / step).rounded() * step
                            }
                            .onEnded { _ in isDraggingLow = false }
                    )

                // High thumb
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: highFrac * trackWidth)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                if !isDraggingHigh {
                                    dragStartHigh = high
                                    isDraggingHigh = true
                                }
                                let pct = drag.translation.width / trackWidth * span
                                let raw = dragStartHigh + pct
                                let clamped = max(low, min(range.upperBound, raw))
                                high = (clamped / step).rounded() * step
                            }
                            .onEnded { _ in isDraggingHigh = false }
                    )
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: thumbSize)
    }
}

// MARK: - Faulty Bulb Detail
private struct FaultyBulbDetail: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState
    var cctRange: ClosedRange<Double> = 2700...6500
    private let throttle = ThrottledSender()
    @State private var lastInverse: Double = 0

    var body: some View {
        VStack(spacing: 12) {
            // Color mode picker: CCT / HSI
            Picker("Mode", selection: $lightState.faultyBulbColorMode) {
                Text("CCT").tag(LightMode.cct)
                Text("HSI").tag(LightMode.hsi)
            }
            .pickerStyle(.segmented)
            .onChange(of: lightState.faultyBulbColorMode) { _ in sendColorNow() }

            // Mode-specific color controls
            if lightState.faultyBulbColorMode == .hsi {
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
                            .onChange(of: lightState.hue) { _ in sendColorNow() }
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
                        .onChange(of: lightState.saturation) { _ in sendColorNow() }
                }
            } else {
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
                            .onChange(of: lightState.cctKelvin) { _ in sendColorNow() }
                    }
                }
            }

            // Fault bias slider (log-scaled: fine control at low values)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Fault")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(Int(lightState.faultyBulbBias) == 0 ? "None" : "\(Int(lightState.faultyBulbBias))")
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(value: $lightState.faultyBulbBias, in: 0...100, step: 1)
                    .onChange(of: lightState.faultyBulbBias) { _ in syncEngineParams() }
            }

            // Frequency slider: 1-9 + R(andom)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Frequency")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(Int(lightState.faultyBulbFrequency) == 10 ? "R" : "\(Int(lightState.faultyBulbFrequency))")
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(value: $lightState.faultyBulbFrequency, in: 1...10, step: 1)
                    .onChange(of: lightState.faultyBulbFrequency) { _ in syncEngineParams() }
            }

            // Inverse slider — moves Fault and Frequency in opposite directions
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Inverse")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(Int(lightState.faultyBulbInverse) == 0 ? "Off" : "\(Int(lightState.faultyBulbInverse))")
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(value: $lightState.faultyBulbInverse, in: 0...9, step: 1)
                    .onChange(of: lightState.faultyBulbInverse) { newValue in
                        let delta = newValue - lastInverse
                        lastInverse = newValue
                        // Fault up: ~11 per step so 9 steps ≈ 100
                        lightState.faultyBulbBias = min(100, max(0, lightState.faultyBulbBias + delta * 11.1))
                        // Frequency down: 1 per step, clamped to 1-9
                        let newFreq = lightState.faultyBulbFrequency - delta
                        lightState.faultyBulbFrequency = min(9, max(1, newFreq))
                        syncEngineParams()
                    }
                    .disabled(Int(lightState.faultyBulbFrequency) == 10)
                    .onAppear { lastInverse = lightState.faultyBulbInverse }
            }
            .opacity(Int(lightState.faultyBulbFrequency) == 10 ? 0.4 : 1.0)

            // Recovery slider — how quickly the bulb returns to high after a dip
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Recovery")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(Int(lightState.faultyBulbRecovery) == 100 ? "Instant" : "\(Int(lightState.faultyBulbRecovery))")
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(value: $lightState.faultyBulbRecovery, in: 0...100, step: 1)
                    .onChange(of: lightState.faultyBulbRecovery) { _ in syncEngineParams() }
            }

            // Warmth slider — shifts CCT warmer on intensity dips (like real incandescent)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Warmth")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(Int(lightState.faultyBulbWarmth) == 0 ? "Off" : "\(Int(lightState.faultyBulbWarmth))")
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(value: $lightState.faultyBulbWarmth, in: 0...100, step: 1)
                    .onChange(of: lightState.faultyBulbWarmth) { _ in syncEngineParams() }
            }

            // Range slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Flicker Range")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(lightState.faultyBulbMin))% – \(Int(lightState.faultyBulbMax))%")
                        .font(.caption)
                        .monospacedDigit()
                }

                RangeSlider(
                    low: $lightState.faultyBulbMin,
                    high: $lightState.faultyBulbMax
                )
                .onChange(of: lightState.faultyBulbMin) { _ in syncEngineParams() }
                .onChange(of: lightState.faultyBulbMax) { _ in syncEngineParams() }
            }

            // Level slider — shifts the entire range up/down keeping the spread
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Level")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(lightState.faultyBulbMin))% – \(Int(lightState.faultyBulbMax))%")
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(
                    value: Binding(
                        get: { lightState.faultyBulbMin },
                        set: { newLow in
                            let spread = lightState.faultyBulbMax - lightState.faultyBulbMin
                            let clamped = min(newLow, 100 - spread)
                            lightState.faultyBulbMin = max(0, clamped)
                            lightState.faultyBulbMax = lightState.faultyBulbMin + spread
                            syncEngineParams()
                        }
                    ),
                    in: 0...100,
                    step: 1
                )
            }

            // Points slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Points")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(lightState.faultyBulbPoints))")
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(value: $lightState.faultyBulbPoints, in: 2...5, step: 1)
                    .onChange(of: lightState.faultyBulbPoints) { _ in syncEngineParams() }
            }

            // Transition slider: instant ↔ 0.20s fade
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Transition")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(lightState.faultyBulbTransition < 0.005 ? "Instant" : String(format: "%.2fs", lightState.faultyBulbTransition))
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(value: $lightState.faultyBulbTransition, in: 0...0.20, step: 0.01)
                    .onChange(of: lightState.faultyBulbTransition) { _ in syncEngineParams() }
            }
        }
    }

    /// Push current lightState params to the running engine
    private func syncEngineParams() {
        bleManager.faultyBulbEngine?.updateParams(from: lightState)
    }

    /// Immediately send the current color at the current intensity so slider changes are instant.
    /// Also pushes updated params to the running engine.
    private func sendColorNow() {
        guard lightState.effectPlaying else { return }
        bleManager.faultyBulbEngine?.updateParams(from: lightState)
        throttle.send { [bleManager, lightState] in
            let intensity = lightState.intensity
            if lightState.faultyBulbColorMode == .hsi {
                bleManager.setHSIWithSleep(
                    intensity: intensity,
                    hue: Int(lightState.hue),
                    saturation: Int(lightState.saturation),
                    cctKelvin: Int(lightState.hsiCCT),
                    sleepMode: 1
                )
            } else {
                bleManager.setCCTWithSleep(
                    intensity: intensity,
                    cctKelvin: Int(lightState.cctKelvin),
                    sleepMode: 1
                )
            }
        }
    }
}

// MARK: - Color Mode Effect Detail (Strobe, Paparazzi, etc.)
private struct ColorModeEffectDetail: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState
    var cctRange: ClosedRange<Double> = 2700...6500
    var onChanged: () -> Void
    var onModeChanged: () -> Void = {}
    @Binding var colorMode: LightMode
    private let throttle = ThrottledSender()

    var body: some View {
        VStack(spacing: 12) {
            // Color mode picker: CCT / HSI
            Picker("Mode", selection: $colorMode) {
                Text("CCT").tag(LightMode.cct)
                Text("HSI").tag(LightMode.hsi)
            }
            .pickerStyle(.segmented)
            .onChange(of: colorMode) { _ in onModeChanged() }

            // Mode-specific color controls
            if colorMode == .hsi {
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
                            .onChange(of: lightState.hue) { _ in onChanged() }
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
                        .onChange(of: lightState.saturation) { _ in onChanged() }
                }
            } else {
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
                            .onChange(of: lightState.cctKelvin) { _ in onChanged() }
                    }
                }
            }

            FrequencySlider(lightState: lightState, onChanged: onChanged)
        }
    }
}

// MARK: - Pulsing Detail
private struct PulsingDetail: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState
    var cctRange: ClosedRange<Double> = 2700...6500
    var onChanged: () -> Void
    var onModeChanged: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            ColorModeEffectDetail(lightState: lightState, cctRange: cctRange, onChanged: onChanged, onModeChanged: onModeChanged, colorMode: $lightState.effectColorMode)

            // Intensity range slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Intensity Range")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(lightState.pulsingMin))% – \(Int(lightState.pulsingMax))%")
                        .font(.caption)
                        .monospacedDigit()
                }

                RangeSlider(
                    low: $lightState.pulsingMin,
                    high: $lightState.pulsingMax
                )
                .onChange(of: lightState.pulsingMin) { _ in syncParams() }
                .onChange(of: lightState.pulsingMax) { _ in syncParams() }
            }

            // Shape slider — skews waveform toward top or bottom, snaps to center (sine)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Shape")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(Int(lightState.pulsingShape) == 50 ? "Sine" : (lightState.pulsingShape < 50 ? "Bottom" : "Top"))
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(
                    value: Binding(
                        get: { lightState.pulsingShape },
                        set: { newValue in
                            // Snap to center (50) when within 3 points
                            lightState.pulsingShape = abs(newValue - 50) < 3 ? 50 : newValue
                        }
                    ),
                    in: 0...100, step: 1
                )
                .onChange(of: lightState.pulsingShape) { _ in syncParams() }
            }
        }
    }

    private func syncParams() {
        bleManager.softwareEffectEngine?.updateParams(from: lightState)
    }
}

// MARK: - Cop Car Detail
private struct CopCarDetail: View {
    @ObservedObject var lightState: LightState
    var onChanged: () -> Void
    private let throttle = ThrottledSender()

    private let colorOptions: [(value: Int, label: String)] = [
        (0, "Red"),
        (2, "Red + Blue"),
        (4, "Red + Blue + White"),
        (1, "Blue"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    ForEach(colorOptions, id: \.value) { option in
                        Button {
                            lightState.copCarColor = option.value
                            throttle.send { onChanged() }
                        } label: {
                            Text(option.label)
                                .font(.caption2)
                                .fontWeight(lightState.copCarColor == option.value ? .bold : .regular)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(
                                    lightState.copCarColor == option.value
                                        ? Color.orange.opacity(0.3)
                                        : Color(.systemGray4)
                                )
                                .foregroundColor(
                                    lightState.copCarColor == option.value
                                        ? .orange
                                        : .primary
                                )
                                .cornerRadius(6)
                        }
                    }
                }
            }

            FrequencySlider(lightState: lightState, onChanged: onChanged)
        }
    }
}

#Preview {
    LightControlView(lightState: LightState())
        .environmentObject(BLEManager())
}
