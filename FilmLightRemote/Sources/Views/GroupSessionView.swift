import SwiftUI

struct GroupSessionView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss

    let group: LightGroup
    @State private var lights: [SavedLight] = []
    @State private var selectedLightId: UUID?
    @State private var lightStates: [UUID: LightState] = [:]
    @State private var showingEditSheet = false
    @State private var currentGroup: LightGroup

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
                        if !bleManager.hasActiveEngine {
                            bleManager.disconnect()
                        }
                        // Save all light states
                        for (id, state) in lightStates {
                            state.save(forLightId: id)
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
            .onReceive(bleManager.$connectionState) { state in
                if state == .ready, let light = selectedLight, let lightState = currentLightState {
                    if lightState.mode == .effects && lightState.selectedEffect == .faultyBulb && lightState.effectPlaying {
                        if bleManager.faultyBulbEngine?.targetAddress != light.unicastAddress {
                            bleManager.startFaultyBulb(lightState: lightState)
                        }
                    }
                }
            }
            .onReceive(bleManager.$lastLightStatus.compactMap { $0 }) { status in
                currentLightState?.applyStatus(status)
            }
            .onDisappear {
                bleManager.stopStatePolling()
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
                        Text(light.name)
                            .font(.subheadline)
                            .fontWeight(selectedLightId == light.id ? .semibold : .regular)
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

    // MARK: - Session Content

    private func sessionContent(light: SavedLight, lightState: LightState) -> some View {
        Group {
            switch bleManager.connectionState {
            case .ready, .connected:
                VStack(spacing: 0) {
                    SlotBar(lightState: lightState, lightId: light.id)
                    LightControlView(
                        lightState: lightState,
                        cctRange: LightSessionView.cctRange(for: light.name),
                        intensityStep: LightSessionView.intensityStep(for: light.name)
                    )
                }
            case .failed(let msg):
                failedView(light: light, message: msg)
            default:
                connectingView(light: light)
            }
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

    // MARK: - Connecting

    private func connectingView(light: SavedLight) -> some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting to \(light.name)...")
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

    private func failedView(light: SavedLight, message: String) -> some View {
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
                bleManager.connectToKnownPeripheral(identifier: light.peripheralIdentifier)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(10)

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
            bleManager.stopStatePolling()
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

        // Disconnect previous (unless background engine) and connect to new
        if !bleManager.hasActiveEngine {
            bleManager.disconnect()
        }
        bleManager.targetUnicastAddress = light.unicastAddress
        bleManager.connectToKnownPeripheral(identifier: light.peripheralIdentifier)
    }
}
