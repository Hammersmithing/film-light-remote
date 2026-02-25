import SwiftUI

/// A/B/C/D preset slots for quickly saving and recalling light looks.
/// Slots are persisted per-light in UserDefaults.
struct SlotBar: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var lightState: LightState
    let lightId: UUID

    @State private var slots: [CueState?] = [nil, nil, nil, nil]
    @State private var tapCounts: [Int] = [0, 0, 0, 0]
    @State private var tapTimers: [Timer?] = [nil, nil, nil, nil]

    private static let keyPrefix = "presetSlots."
    private let labels = ["A", "B", "C", "D"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                slotButton(index: index, label: label)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onAppear { loadSlots() }
    }

    // MARK: - Slot Button

    private func slotButton(index: Int, label: String) -> some View {
        let slot = slots[index]
        let isActive = slot.map { matchesCurrent($0) } ?? false

        return Button {
            tapped(index)
        } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                if let slot = slot {
                    Text(slot.shortSummary)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(slotBackground(slot: slot))
            .foregroundColor(slot != nil ? .white : .secondary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isActive ? Color.white : Color.secondary.opacity(slot != nil ? 0 : 0.5),
                                  lineWidth: isActive ? 2 : 1)
            )
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    save(to: index)
                }
        )
    }

    // MARK: - Tap Tracking

    private func tapped(_ index: Int) {
        // Recall immediately on every tap (instant haptic + BLE)
        if let slot = slots[index] {
            recall(slot)
        }

        // Track rapid taps — clear on 3rd within 0.6s
        tapTimers[index]?.invalidate()
        tapCounts[index] += 1
        if tapCounts[index] >= 3 {
            tapCounts[index] = 0
            clear(index)
        } else {
            tapTimers[index] = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                DispatchQueue.main.async {
                    tapCounts[index] = 0
                }
            }
        }
    }

    // MARK: - Appearance

    private func slotBackground(slot: CueState?) -> some ShapeStyle {
        guard let slot = slot else {
            return AnyShapeStyle(Color.clear)
        }
        return AnyShapeStyle(modeColor(for: slot).opacity(0.85))
    }

    private func modeColor(for state: CueState) -> Color {
        let mode = LightMode(rawValue: state.mode) ?? .cct
        switch mode {
        case .cct: return .orange
        case .hsi: return .blue
        case .effects: return .purple
        }
    }

    private func matchesCurrent(_ slot: CueState) -> Bool {
        let current = CueState.from(lightState)
        return current.mode == slot.mode
            && current.intensity == slot.intensity
            && current.cctKelvin == slot.cctKelvin
            && current.hue == slot.hue
            && current.saturation == slot.saturation
            && current.hsiIntensity == slot.hsiIntensity
            && current.effectId == slot.effectId
    }

    // MARK: - Actions

    private func save(to index: Int) {
        slots[index] = CueState.from(lightState)
        persistSlots()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func clear(_ index: Int) {
        guard slots[index] != nil else { return }
        slots[index] = nil
        persistSlots()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func recall(_ slot: CueState) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Stop any currently playing effect before switching
        if lightState.effectPlaying {
            lightState.effectPlaying = false
            bleManager.stopEffect()
            bleManager.stopFaultyBulb()
        }

        let targetMode = LightMode(rawValue: slot.mode) ?? .cct

        // Set mode first so SwiftUI removes the old mode's onChange handlers
        // (prevents stale HSI sends when recalling CCT and vice versa)
        lightState.mode = targetMode

        // Apply full state and send BLE after the view update cycle
        DispatchQueue.main.async { [bleManager, lightState] in
            slot.apply(to: lightState)
            bleManager.syncState(from: lightState)

            switch targetMode {
            case .cct:
                bleManager.setCCTWithSleep(
                    intensity: lightState.intensity,
                    cctKelvin: Int(lightState.cctKelvin),
                    sleepMode: 1)
            case .hsi:
                bleManager.setHSIWithSleep(
                    intensity: lightState.hsiIntensity,
                    hue: Int(lightState.hue),
                    saturation: Int(lightState.saturation),
                    cctKelvin: Int(lightState.hsiCCT),
                    sleepMode: 1)
            case .effects:
                let effect = LightEffect(rawValue: slot.effectId) ?? .none
                guard effect != .none else { return }
                lightState.effectPlaying = true
                if effect == .faultyBulb {
                    bleManager.startFaultyBulb(lightState: lightState)
                } else if effect == .paparazzi && lightState.paparazziColorMode == .hsi {
                    bleManager.startPaparazzi(lightState: lightState)
                } else if effect == .pulsing || effect == .strobe || effect == .party {
                    bleManager.startSoftwareEffect(lightState: lightState)
                } else if effect != .copCar && lightState.effectColorMode == .hsi {
                    bleManager.startSoftwareEffect(lightState: lightState)
                } else {
                    bleManager.setEffect(
                        effectType: effect.rawValue,
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

    // MARK: - Persistence

    private func persistSlots() {
        if let data = try? JSONEncoder().encode(slots) {
            UserDefaults.standard.set(data, forKey: Self.keyPrefix + lightId.uuidString)
        }
    }

    private func loadSlots() {
        guard let data = UserDefaults.standard.data(forKey: Self.keyPrefix + lightId.uuidString),
              let decoded = try? JSONDecoder().decode([CueState?].self, from: data) else { return }
        slots = decoded
    }
}
