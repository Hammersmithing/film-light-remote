import SwiftUI

/// Edit one light's From and To positions within a move.
/// Connects directly to the light so the user sees changes in real time.
/// Always shows From/To tabs since every move is inherently A→B.
struct MoveLightEditorView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject private var bridgeManager = BridgeManager.shared
    @State private var entry: MoveLightEntry
    @StateObject private var lightState = LightState()
    @State private var selectedPosition: Position = .to
    var onSave: (MoveLightEntry) -> Void

    enum Position: String, CaseIterable {
        case from = "From"
        case to = "To"
    }

    /// Stored snapshots so switching tabs preserves edits.
    @State private var stateFrom: CueState
    @State private var stateTo: CueState

    @State private var previousUnicastAddress: UInt16 = 0

    private var usingBridge: Bool { bridgeManager.isConnected }

    init(entry: MoveLightEntry, onSave: @escaping (MoveLightEntry) -> Void) {
        _entry = State(initialValue: entry)
        _stateFrom = State(initialValue: entry.fromState)
        _stateTo = State(initialValue: entry.toState)
        self.onSave = onSave
    }

    private var cctRange: ClosedRange<Double> {
        LightSessionView.cctRange(for: entry.lightName)
    }

    private var intensityStep: Double {
        LightSessionView.intensityStep(for: entry.lightName)
    }

    private var isLightReady: Bool {
        usingBridge || bleManager.connectionState == .ready
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
                if !usingBridge && bleManager.connectionState != .ready {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Connecting...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemGray6))

            // From/To picker
            Picker("Position", selection: $selectedPosition) {
                ForEach(Position.allCases, id: \.self) { pos in
                    Text(pos.rawValue).tag(pos)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .onChange(of: selectedPosition) { _ in
                switchPosition()
            }

            // Position label
            Text(selectedPosition == .from ? "Start Position" : "End Position")
                .font(.caption)
                .foregroundColor(selectedPosition == .from ? .blue : .green)
                .padding(.top, 4)

            // Light controls
            LightControlView(
                lightState: lightState,
                cctRange: cctRange,
                intensityStep: intensityStep
            )
            .allowsHitTesting(isLightReady)
            .opacity(isLightReady ? 1.0 : 0.5)
        }
        .navigationTitle(selectedPosition == .from ? "From" : "To")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveCurrentPosition()
                    entry.fromState = stateFrom
                    entry.toState = stateTo
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
            previousUnicastAddress = bleManager.targetUnicastAddress
            bleManager.suppressStatusUpdates = true
            bleManager.targetUnicastAddress = entry.unicastAddress

            if usingBridge {
                bridgeManager.connectLight(unicast: entry.unicastAddress)
            } else {
                if let saved = KeyStorage.shared.savedLights.first(where: { $0.id == entry.lightId }) {
                    bleManager.connectToKnownPeripheral(identifier: saved.peripheralIdentifier)
                }
            }

            // Start on From position
            selectedPosition = .from
            stateFrom.apply(to: lightState)
        }
        .onDisappear {
            bleManager.suppressStatusUpdates = false
            bleManager.targetUnicastAddress = previousUnicastAddress
            if !usingBridge {
                bleManager.disconnect()
            }
        }
    }

    /// Save the current lightState into the active position's snapshot.
    private func saveCurrentPosition() {
        let snapshot = CueState.from(lightState)
        if selectedPosition == .from {
            stateFrom = snapshot
        } else {
            stateTo = snapshot
        }
    }

    /// Switch between From and To — save current edits, load the other position.
    private func switchPosition() {
        let snapshot = CueState.from(lightState)
        if selectedPosition == .from {
            // Just switched TO From, so save To
            stateTo = snapshot
            stateFrom.apply(to: lightState)
        } else {
            // Just switched TO To, so save From
            stateFrom = snapshot
            stateTo.apply(to: lightState)
        }
    }
}
