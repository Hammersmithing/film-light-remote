import SwiftUI

struct MyLightsView: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var savedLights: [SavedLight] = []
    @State private var showingAddLight = false
    @State private var showingDebugLog = false
    @State private var selectedLight: SavedLight?

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
                    LightRow(light: light)
                }
                .tint(.primary)
            }
            .onDelete(perform: deleteLights)
        }
    }

    // MARK: - Actions

    private func reloadLights() {
        savedLights = KeyStorage.shared.savedLights
    }

    private func deleteLights(at offsets: IndexSet) {
        for index in offsets {
            KeyStorage.shared.removeSavedLight(savedLights[index])
        }
        reloadLights()
    }
}

// MARK: - Light Row

private struct LightRow: View {
    let light: SavedLight

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lightbulb.fill")
                .font(.title2)
                .foregroundColor(.yellow)
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

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
