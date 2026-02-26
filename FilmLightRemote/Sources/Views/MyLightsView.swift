import SwiftUI

struct MyLightsView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject private var bridgeManager = BridgeManager.shared
    @State private var savedLights: [SavedLight] = []
    @State private var showingAddLight = false
    @State private var showingDebugLog = false
    @State private var selectedLight: SavedLight?
    @State private var renamingLight: SavedLight?
    @State private var renameText: String = ""

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
            .onAppear {
                reloadLights()
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
                let lightConnected = bridgeManager.lightStatuses[light.unicastAddress] == true
                Button {
                    selectedLight = light
                } label: {
                    LightRow(light: light, isConnected: lightConnected, onRename: {
                        renameText = light.name
                        renamingLight = light
                    }, onDelete: {
                        KeyStorage.shared.removeSavedLight(light)
                        reloadLights()
                    })
                }
                .tint(.primary)
                .disabled(!bridgeManager.isConnected)
            }
        }
    }

    // MARK: - Actions

    private func reloadLights() {
        savedLights = KeyStorage.shared.savedLights
    }

}

// MARK: - Light Row

private struct LightRow: View {
    let light: SavedLight
    let isConnected: Bool
    var onRename: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lightbulb.fill")
                .font(.title2)
                .foregroundColor(isConnected ? .yellow : .gray)
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
