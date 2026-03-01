import SwiftUI

struct GroupSessionView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject private var bridgeManager = BridgeManager.shared
    @Environment(\.dismiss) var dismiss

    let group: LightGroup
    @State private var lights: [SavedLight] = []
    @State private var selectedLightId: UUID?
    @State private var lightStates: [UUID: LightState] = [:]
    @State private var showingEditSheet = false
    @State private var currentGroup: LightGroup

    private var usingBridge: Bool { bridgeManager.isConnected }

    init(group: LightGroup) {
        self.group = group
        _currentGroup = State(initialValue: group)
    }

    private var selectedLight: SavedLight? {
        lights.first { $0.id == selectedLightId }
    }

    private var currentLightState: LightState? {
        guard let id = selectedLightId else { return nil }
        return lightStates[id]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                lightPicker
                Divider()
                if let light = selectedLight, let state = currentLightState {
                    sessionContent(light: light, lightState: state)
                } else {
                    noLightsView
                }
            }
            .navigationTitle(currentGroup.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        // Save all light states
                        for (id, state) in lightStates {
                            state.save(forLightId: id)
                        }
                        if !usingBridge {
                            bleManager.disconnect()
                        }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingEditSheet = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                }
            }
            .sheet(isPresented: $showingEditSheet) {
                groupEditSheet
            }
            .onAppear {
                reloadLights()
                // Auto-select first light
                if selectedLightId == nil, let first = lights.first {
                    selectLight(first)
                }
            }
            .onDisappear {
                for (id, state) in lightStates {
                    state.save(forLightId: id)
                }
            }
        }
    }

    // MARK: - Light Picker

    private var lightPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(lights) { light in
                    Button {
                        selectLight(light)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(lightStatusColor(for: light))
                                .frame(width: 8, height: 8)
                            Text(light.name)
                                .font(.subheadline)
                                .fontWeight(selectedLightId == light.id ? .semibold : .regular)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(selectedLightId == light.id ? Color.accentColor : Color(.systemGray5))
                        )
                        .foregroundColor(selectedLightId == light.id ? .white : .primary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

    private func lightStatusColor(for light: SavedLight) -> Color {
        if usingBridge {
            if bridgeManager.lightStatuses[light.unicastAddress] == true {
                return .green
            }
            return .gray
        } else {
            // In direct BLE mode, only the currently connected light shows green
            if light.id == selectedLightId && bleManager.connectionState == .ready {
                return .green
            }
            return .gray
        }
    }

    // MARK: - Session Content

    private func sessionContent(light: SavedLight, lightState: LightState) -> some View {
        VStack(spacing: 0) {
            SlotBar(lightState: lightState, lightId: light.id)
            LightControlView(
                lightState: lightState,
                cctRange: LightSessionView.cctRange(for: light.name),
                intensityStep: LightSessionView.intensityStep(for: light.name)
            )
        }
    }

    // MARK: - No Lights

    private var noLightsView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lightbulb.2")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text("No Lights in Group")
                .font(.headline)
            Text("Tap the pencil icon to add lights")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Edit Sheet

    private var groupEditSheet: some View {
        NavigationStack {
            List {
                let allLights = KeyStorage.shared.savedLights
                if allLights.isEmpty {
                    Text("No saved lights.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(allLights) { light in
                        let isSelected = currentGroup.lightIds.contains(light.id)
                        Button {
                            if isSelected {
                                currentGroup.lightIds.removeAll { $0 == light.id }
                            } else {
                                currentGroup.lightIds.append(light.id)
                            }
                            KeyStorage.shared.updateLightGroup(currentGroup)
                            reloadLights()
                        } label: {
                            HStack {
                                Image(systemName: "lightbulb.fill")
                                    .foregroundColor(.yellow)
                                VStack(alignment: .leading) {
                                    Text(light.name)
                                    Text(light.lightType)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Edit Lights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showingEditSheet = false }
                }
            }
        }
    }

    // MARK: - Actions

    private func reloadLights() {
        let allSaved = KeyStorage.shared.savedLights
        lights = currentGroup.lightIds.compactMap { id in
            allSaved.first { $0.id == id }
        }
        // Ensure light states exist for all lights
        for light in lights {
            if lightStates[light.id] == nil {
                let state = LightState()
                state.load(forLightId: light.id)
                lightStates[light.id] = state
            }
        }
        // If selected light was removed, select first available
        if let sel = selectedLightId, !lights.contains(where: { $0.id == sel }) {
            if let first = lights.first {
                selectLight(first)
            } else {
                selectedLightId = nil
            }
        }
    }

    private func selectLight(_ light: SavedLight) {
        // Save state of previous light
        if let prevId = selectedLightId, let prevState = lightStates[prevId] {
            prevState.save(forLightId: prevId)
        }

        selectedLightId = light.id

        // Ensure state exists
        if lightStates[light.id] == nil {
            let state = LightState()
            state.load(forLightId: light.id)
            lightStates[light.id] = state
        }

        if let state = lightStates[light.id] {
            bleManager.syncState(from: state)
        }

        // Point BLE commands at this light's unicast address
        bleManager.targetUnicastAddress = light.unicastAddress

        if usingBridge {
            // Ask bridge to connect to this light
            bridgeManager.connectLight(unicast: light.unicastAddress)
        } else {
            // Direct BLE: connect to this light's peripheral (disconnects previous)
            bleManager.connectToKnownPeripheral(identifier: light.peripheralIdentifier)
        }
    }
}
