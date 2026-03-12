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
    @State private var syncMode = false
    @State private var syncLightState: LightState?

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
                lightPickerBar
                Divider()
                if syncMode, let state = syncLightState {
                    syncContent(lightState: state)
                } else if let light = selectedLight, let state = currentLightState {
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

                        for (id, state) in lightStates {
                            state.save(forLightId: id)
                        }
                        bleManager.groupTargetAddress = nil
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
                bleManager.groupTargetAddress = nil
            }
        }
    }

    // MARK: - Light Picker Bar

    private var lightPickerBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if currentGroup.meshGroupAddress != nil && lights.count >= 2 {
                    syncToggle
                }
                if !syncMode {
                    lightPicker
                } else {
                    Text("All Lights")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.accentColor))
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

    private var syncToggle: some View {
        Button {
            toggleSync()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: syncMode ? "link.circle.fill" : "link.circle")
                    .font(.body)
                Text("Sync")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(syncMode ? Color.orange : Color(.systemGray5)))
            .foregroundColor(syncMode ? .white : .primary)
        }
    }

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
        }
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

    private func syncContent(lightState: LightState) -> some View {
        VStack(spacing: 0) {
            LightControlView(
                lightState: lightState,
                cctRange: 2000...10000,
                intensityStep: 1.0
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

    private func toggleSync() {
        syncMode.toggle()
        if syncMode {
            // Initialize sync state from currently selected light
            if syncLightState == nil {
                let state = LightState()
                if let id = selectedLightId, let existing = lightStates[id] {
                    state.copyValues(from: existing)
                }
                syncLightState = state
            }
            if let state = syncLightState {
                bleManager.syncState(from: state)
            }
            // Route commands to group address (relay delivers to all lights)
            guard let groupAddr = currentGroup.meshGroupAddress else { return }
            bleManager.groupTargetAddress = groupAddr
        } else {
            // Disable sync
            bleManager.groupTargetAddress = nil
            if let light = selectedLight {
                bleManager.targetUnicastAddress = light.unicastAddress
                if let state = lightStates[light.id] {
                    bleManager.syncState(from: state)
                }
            }
        }
    }

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
            // Send current state immediately so light matches sliders
            sendCurrentState(for: light)
        } else {
            // Direct BLE: connect to this light's peripheral (disconnects previous)
            bleManager.connectToKnownPeripheral(identifier: light.peripheralIdentifier)
            // Send current state once connected (after a brief delay for connection)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                if selectedLightId == light.id {
                    sendCurrentState(for: light)
                }
            }
        }
    }

    /// Send the light's saved state immediately so it matches the UI without requiring slider adjustment
    private func sendCurrentState(for light: SavedLight) {
        guard let state = lightStates[light.id] else { return }
        if state.mode == .cct {
            bleManager.setCCT(Int(state.cctKelvin), gm: Int(state.gmTint))
        } else {
            bleManager.setHSI(
                hue: Int(state.hue),
                saturation: Int(state.saturation),
                intensity: Int(state.hsiIntensity),
                cctKelvin: Int(state.hsiCCT)
            )
        }
    }
}
