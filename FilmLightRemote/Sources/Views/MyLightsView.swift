import SwiftUI

struct MyLightsView: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var savedLights: [SavedLight] = []
    @State private var showingAddLight = false
    @State private var showingDebugLog = false
    @State private var selectedLight: SavedLight?
    @State private var renamingLight: SavedLight?
    @State private var renameText: String = ""
    @State private var powerStates: [UUID: Bool] = [:]
    /// Light waiting for connection to complete before toggling power
    @State private var pendingPowerToggle: SavedLight?

    var body: some View {
        NavigationStack {
            Group {
                if savedLights.isEmpty {
                    emptyState
                } else {
                    lightsList
                }
            }
            .navigationTitle("My Lights")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingDebugLog = true
                    } label: {
                        Image(systemName: "terminal")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddLight = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!bleManager.isBluetoothAvailable)
                }
            }
            .sheet(isPresented: $showingDebugLog) {
                DebugLogView()
            }
            .fullScreenCover(isPresented: $showingAddLight) {
                AddLightFlowView {
                    reloadLights()
                }
            }
            .fullScreenCover(item: $selectedLight) { light in
                LightSessionView(savedLight: light)
            }
            .onChange(of: selectedLight) { light in
                // When returning from a light session, refresh power states
                if light == nil {
                    reloadPowerStates()
                }
            }
            .onAppear {
                reloadLights()
            }
            .onReceive(bleManager.$connectionState) { state in
                if state == .ready, let light = pendingPowerToggle {
                    let newState = powerStates[light.id] ?? true
                    bleManager.targetUnicastAddress = light.unicastAddress
                    bleManager.setPowerOn(newState)
                    pendingPowerToggle = nil
                }
            }
            .alert("Rename Light", isPresented: Binding(
                get: { renamingLight != nil },
                set: { if !$0 { renamingLight = nil } }
            )) {
                TextField("Light name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingLight = nil }
                Button("Save") {
                    if let light = renamingLight, !renameText.isEmpty {
                        var updated = light
                        updated.name = renameText
                        KeyStorage.shared.updateSavedLight(updated)
                        reloadLights()
                    }
                    renamingLight = nil
                }
            } message: {
                Text("Enter a new name for this light.")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lightbulb.2")
                .font(.system(size: 70))
                .foregroundColor(.secondary)

            Text("No Lights Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add your first light to get started")
                .font(.body)
                .foregroundColor(.secondary)

            Button {
                showingAddLight = true
            } label: {
                Label("Add Light", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
            .disabled(!bleManager.isBluetoothAvailable)

            if !bleManager.isBluetoothAvailable {
                Text("Bluetooth is not available")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Lights List

    private var lightsList: some View {
        List {
            ForEach(savedLights) { light in
                Button {
                    selectedLight = light
                } label: {
                    LightRow(light: light, isOn: powerStates[light.id] ?? true, onPowerToggle: {
                        togglePower(for: light)
                    }, onRename: {
                        renameText = light.name
                        renamingLight = light
                    }, onDelete: {
                        KeyStorage.shared.removeSavedLight(light)
                        reloadLights()
                    })
                }
                .tint(.primary)
            }
        }
    }

    // MARK: - Actions

    private func reloadLights() {
        savedLights = KeyStorage.shared.savedLights
        reloadPowerStates()
    }

    private func reloadPowerStates() {
        for light in savedLights {
            let state = LightState()
            state.load(forLightId: light.id)
            powerStates[light.id] = state.isOn
        }
    }

    private func togglePower(for light: SavedLight) {
        let newState = !(powerStates[light.id] ?? true)
        powerStates[light.id] = newState

        // Persist the power state
        let state = LightState()
        state.load(forLightId: light.id)
        state.isOn = newState
        state.save(forLightId: light.id)

        // If already connected, send immediately
        if bleManager.connectedPeripheral != nil && bleManager.connectionState == .ready {
            let previousTarget = bleManager.targetUnicastAddress
            bleManager.targetUnicastAddress = light.unicastAddress
            bleManager.setPowerOn(newState)
            bleManager.targetUnicastAddress = previousTarget
        } else {
            // Need to connect first — update pending state (connection may already be in progress)
            pendingPowerToggle = light
            bleManager.targetUnicastAddress = light.unicastAddress
            // Only start a new connection if not already connecting
            let shouldConnect: Bool = {
                switch bleManager.connectionState {
                case .disconnected, .failed: return true
                default: return false
                }
            }()
            if shouldConnect {
                bleManager.connectToKnownPeripheral(identifier: light.peripheralIdentifier)
            }
        }
    }
}

// MARK: - Light Row

private struct LightRow: View {
    let light: SavedLight
    var isOn: Bool
    var onPowerToggle: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lightbulb.fill")
                .font(.title2)
                .foregroundColor(isOn ? .yellow : .gray)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(light.name)
                    .font(.body)
                    .fontWeight(.medium)

                Text(light.lightType)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                onPowerToggle()
            } label: {
                Image(systemName: isOn ? "power.circle.fill" : "power.circle")
                    .font(.title2)
                    .foregroundColor(isOn ? .green : .gray)
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
    }
}
