import SwiftUI

/// Presented as a fullScreenCover when the user taps a saved light.
/// Reconnects to the peripheral and shows LightControlView when ready.
struct LightSessionView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss
    @StateObject private var lightState = LightState()

    let savedLight: SavedLight

    var body: some View {
        NavigationStack {
            Group {
                switch bleManager.connectionState {
                case .ready, .connected:
                    LightControlView(lightState: lightState, cctRange: Self.cctRange(for: savedLight.name), intensityStep: Self.intensityStep(for: savedLight.name))
                case .failed(let msg):
                    failedView(message: msg)
                default:
                    connectingView
                }
            }
            .navigationTitle(savedLight.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        // If a background engine is running, keep the BLE connection alive
                        if !bleManager.hasActiveEngine {
                            bleManager.disconnect()
                        }
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Clear stale status so it doesn't override loaded state
            bleManager.lastLightStatus = nil
            lightState.load(forLightId: savedLight.id)
            // If the engine is already running for this light, reflect that in the UI
            if bleManager.faultyBulbEngine?.targetAddress == savedLight.unicastAddress {
                lightState.mode = .effects
                lightState.selectedEffect = .faultyBulb
                lightState.effectPlaying = true
            }
            bleManager.syncState(from: lightState)
            bleManager.targetUnicastAddress = savedLight.unicastAddress
            bleManager.connectToKnownPeripheral(identifier: savedLight.peripheralIdentifier)
        }
        .onReceive(bleManager.$connectionState) { state in
            if state == .ready {
                // Sync power state to match what the app expects
                bleManager.setPowerOn(lightState.isOn)

                // Restart faulty bulb engine if it was actively playing,
                // but skip if already running for this light (e.g. reopening session)
                if lightState.mode == .effects && lightState.selectedEffect == .faultyBulb && lightState.effectPlaying {
                    if bleManager.faultyBulbEngine?.targetAddress != savedLight.unicastAddress {
                        bleManager.startFaultyBulb(lightState: lightState)
                    }
                }
            }
        }
        .onReceive(bleManager.$lastLightStatus.compactMap { $0 }) { status in
            lightState.applyStatus(status)
        }
        .onDisappear {
            bleManager.stopStatePolling()
            lightState.save(forLightId: savedLight.id)
        }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting to \(savedLight.name)...")
                .font(.headline)
            Text(stateDescription)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var stateDescription: String {
        switch bleManager.connectionState {
        case .scanning: return "Scanning for light..."
        case .connecting: return "Establishing connection..."
        case .discoveringServices: return "Discovering services..."
        default: return ""
        }
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 50))
                .foregroundColor(.secondary)

            Text("Could Not Connect")
                .font(.title3)
                .fontWeight(.semibold)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                bleManager.connectToKnownPeripheral(identifier: savedLight.peripheralIdentifier)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(10)

            Spacer()
        }
    }

    // MARK: - CCT Range Lookup

    static func cctRange(for name: String) -> ClosedRange<Double> {
        if name.localizedCaseInsensitiveContains("660C") {
            return 1800...20000
        }
        return 2700...6500
    }

    static func intensityStep(for name: String) -> Double {
        if name.localizedCaseInsensitiveContains("660C") {
            return 0.1
        }
        return 1.0
    }
}
