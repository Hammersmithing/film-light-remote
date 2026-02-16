import SwiftUI

/// Edit one light's state within a cue — sends live BLE commands so the user
/// can see their changes on the actual light through the mesh proxy.
struct CueLightEditorView: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var entry: LightCueEntry
    @StateObject private var lightState = LightState()
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
            // Header
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text(entry.lightName)
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(.systemGray6))

            // Full LightControlView — sends live BLE so the user sees changes
            LightControlView(
                lightState: lightState,
                cctRange: cctRange,
                intensityStep: intensityStep
            )
        }
        .navigationTitle("Edit Light State")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    entry.state = CueState.from(lightState)
                    restoreAddress()
                    onSave(entry)
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    restoreAddress()
                    onSave(entry) // return unchanged
                }
            }
        }
        .onAppear {
            // Point BLE commands at this light's unicast address
            previousUnicastAddress = bleManager.targetUnicastAddress
            bleManager.targetUnicastAddress = entry.unicastAddress
            // Block status feedback from the proxy — it's a different light
            // and would overwrite slider values
            bleManager.suppressStatusUpdates = true
            entry.state.apply(to: lightState)
        }
        .onDisappear {
            bleManager.suppressStatusUpdates = false
            restoreAddress()
        }
    }

    private func restoreAddress() {
        bleManager.suppressStatusUpdates = false
        bleManager.targetUnicastAddress = previousUnicastAddress
    }
}
