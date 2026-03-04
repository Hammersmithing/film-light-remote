import SwiftUI

/// Edit one light's state within a cue — connects directly to the light's
/// BLE peripheral (or via bridge) so the user sees their changes in real time.
struct CueLightEditorView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject private var bridgeManager = BridgeManager.shared
    @State private var entry: LightCueEntry
    @StateObject private var lightState = LightState()
    var onSave: (LightCueEntry) -> Void

    /// Unicast address before we switched to this light (restored on dismiss).
    @State private var previousUnicastAddress: UInt16 = 0

    private var usingBridge: Bool { bridgeManager.isConnected }

    init(entry: LightCueEntry, onSave: @escaping (LightCueEntry) -> Void) {
        _entry = State(initialValue: entry)
        self.onSave = onSave
    }

    private var cctRange: ClosedRange<Double> {
        LightSessionView.cctRange(for: entry.lightName)
    }

    private var intensityStep: Double {
        LightSessionView.intensityStep(for: entry.lightName)
    }

    private var isLightReady: Bool {
        if usingBridge {
            return true
        } else {
            return bleManager.connectionState == .ready
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with connection status
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text(entry.lightName)
                    .font(.headline)
                Spacer()
                if !usingBridge && bleManager.connectionState != .ready {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Connecting via BLE...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemGray6))

            // Full LightControlView — sends live commands
            LightControlView(
                lightState: lightState,
                cctRange: cctRange,
                intensityStep: intensityStep
            )
            .allowsHitTesting(isLightReady)
            .opacity(isLightReady ? 1.0 : 0.5)
        }
        .navigationTitle("Edit Light State")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    entry.state = CueState.from(lightState)
                    onSave(entry)
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onSave(entry) // return unchanged
                }
            }
        }
        .onAppear {
            // Save current address so we can restore later
            previousUnicastAddress = bleManager.targetUnicastAddress

            // Block status feedback — the proxy light's status would overwrite sliders
            bleManager.suppressStatusUpdates = true

            // Point commands at this light
            bleManager.targetUnicastAddress = entry.unicastAddress

            if usingBridge {
                bridgeManager.connectLight(unicast: entry.unicastAddress)
            } else {
                // Look up peripheral identifier from saved lights
                if let saved = KeyStorage.shared.savedLights.first(where: { $0.id == entry.lightId }) {
                    bleManager.connectToKnownPeripheral(identifier: saved.peripheralIdentifier)
                }
            }

            entry.state.apply(to: lightState)
        }
        .onDisappear {
            bleManager.suppressStatusUpdates = false
            bleManager.targetUnicastAddress = previousUnicastAddress
            if !usingBridge {
                bleManager.disconnect()
            }
        }
    }
}
