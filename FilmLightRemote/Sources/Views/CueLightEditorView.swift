import SwiftUI

/// Edit one light's state within a cue — connects directly to the light's
/// BLE peripheral so the user sees their changes in real time.
struct CueLightEditorView: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var entry: LightCueEntry
    @StateObject private var lightState = LightState()
    @State private var isReady = false
    var onSave: (LightCueEntry) -> Void

    /// Unicast address before we switched to this light (restored on dismiss).
    @State private var previousUnicastAddress: UInt16 = 0

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

    var body: some View {
        VStack(spacing: 0) {
            // Header with connection status
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text(entry.lightName)
                    .font(.headline)
                Spacer()
                if !isReady {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Connecting...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemGray6))

            // Full LightControlView — sends live BLE so the user sees changes
            LightControlView(
                lightState: lightState,
                cctRange: cctRange,
                intensityStep: intensityStep
            )
            .allowsHitTesting(isReady)
            .opacity(isReady ? 1.0 : 0.5)
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

            // Connect directly to this light's peripheral for live preview
            bleManager.targetUnicastAddress = entry.unicastAddress
            if let saved = KeyStorage.shared.savedLights.first(where: { $0.id == entry.lightId }) {
                // Check if already connected to this light
                if bleManager.connectedPeripheral?.identifier == saved.peripheralIdentifier,
                   bleManager.connectionState == .ready {
                    isReady = true
                } else {
                    isReady = false
                    bleManager.connectToKnownPeripheral(identifier: saved.peripheralIdentifier)
                }
            }

            entry.state.apply(to: lightState)
        }
        .onReceive(bleManager.$connectionState) { state in
            if state == .ready {
                isReady = true
            }
        }
        .onDisappear {
            bleManager.suppressStatusUpdates = false
            bleManager.targetUnicastAddress = previousUnicastAddress
        }
    }
}
