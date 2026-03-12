import SwiftUI

/// Edit one light's A and B positions within a cue.
/// Connects directly to the light so the user sees changes in real time.
/// Tab between Position A (start) and Position B (end) to set each look.
struct CueLightEditorView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject private var bridgeManager = BridgeManager.shared
    @State private var entry: LightCueEntry
    @StateObject private var lightState = LightState()
    @State private var selectedPosition: Position = .b
    @State private var hasPositionA: Bool
    var onSave: (LightCueEntry) -> Void

    enum Position: String, CaseIterable {
        case a = "A"
        case b = "B"
    }

    /// Stored snapshots so switching tabs preserves edits.
    @State private var stateA: CueState
    @State private var stateB: CueState

    @State private var previousUnicastAddress: UInt16 = 0

    private var usingBridge: Bool { bridgeManager.isConnected }

    init(entry: LightCueEntry, onSave: @escaping (LightCueEntry) -> Void) {
        _entry = State(initialValue: entry)
        _stateA = State(initialValue: entry.startState ?? CueState())
        _stateB = State(initialValue: entry.state)
        _hasPositionA = State(initialValue: entry.startState != nil)
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

            // A/B toggle
            if hasPositionA {
                Picker("Position", selection: $selectedPosition) {
                    ForEach(Position.allCases, id: \.self) { pos in
                        Text("Position \(pos.rawValue)").tag(pos)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .onChange(of: selectedPosition) { _ in
                    switchPosition()
                }
            }

            // Enable/disable position A
            Toggle(hasPositionA ? "Fade A \u{2192} B" : "Enable Fade (A \u{2192} B)", isOn: $hasPositionA)
                .padding(.horizontal)
                .padding(.top, 8)
                .onChange(of: hasPositionA) { enabled in
                    if enabled {
                        // Copy current B state as starting point for A
                        stateA = stateB
                        selectedPosition = .a
                        stateA.apply(to: lightState)
                    } else {
                        selectedPosition = .b
                        stateB.apply(to: lightState)
                    }
                }

            // Position label
            if hasPositionA {
                Text(selectedPosition == .a ? "Start Position" : "End Position")
                    .font(.caption)
                    .foregroundColor(selectedPosition == .a ? .blue : .green)
                    .padding(.top, 4)
            }

            // Light controls
            LightControlView(
                lightState: lightState,
                cctRange: cctRange,
                intensityStep: intensityStep
            )
            .allowsHitTesting(isLightReady)
            .opacity(isLightReady ? 1.0 : 0.5)
        }
        .navigationTitle(hasPositionA ? "Position \(selectedPosition.rawValue)" : "Edit Light")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveCurrentPosition()
                    entry.state = stateB
                    entry.startState = hasPositionA ? stateA : nil
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

            // Load initial position into controls
            if hasPositionA {
                selectedPosition = .a
                stateA.apply(to: lightState)
            } else {
                stateB.apply(to: lightState)
            }
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
        if selectedPosition == .a {
            stateA = snapshot
        } else {
            stateB = snapshot
        }
    }

    /// Switch between A and B — save current edits, load the other position.
    private func switchPosition() {
        // Save what we were editing
        let snapshot = CueState.from(lightState)
        if selectedPosition == .a {
            // We just switched TO A, so save B
            stateB = snapshot
            stateA.apply(to: lightState)
        } else {
            // We just switched TO B, so save A
            stateA = snapshot
            stateB.apply(to: lightState)
        }
    }
}
