import SwiftUI

/// Presented as a fullScreenCover when the user taps a saved light.
/// Connects via the bridge and shows LightControlView when ready.
struct LightSessionView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss
    @StateObject private var lightState = LightState()
    @ObservedObject private var bridgeManager = BridgeManager.shared

    let savedLight: SavedLight

    private var isLightConnected: Bool {
        bridgeManager.lightStatuses[savedLight.unicastAddress] == true
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLightConnected {
                    LightControlView(lightState: lightState, cctRange: Self.cctRange(for: savedLight.name), intensityStep: Self.intensityStep(for: savedLight.name))
                } else if let error = bridgeManager.lastError {
                    failedView(message: error)
                } else {
                    connectingView
                }
            }
            .navigationTitle(savedLight.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            lightState.load(forLightId: savedLight.id)
            bleManager.syncState(from: lightState)
            bleManager.targetUnicastAddress = savedLight.unicastAddress
            bridgeManager.connectLight(unicast: savedLight.unicastAddress)
        }
        .onDisappear {
            lightState.save(forLightId: savedLight.id)
        }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting to \(savedLight.name)...")
                .font(.headline)
            Text("Via bridge")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
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
                bridgeManager.connectLight(unicast: savedLight.unicastAddress)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(10)

            Spacer()
        }
    }

    // MARK: - CCT Range Lookup

    static func cctRange(for name: String) -> ClosedRange<Double> {
        if name.localizedCaseInsensitiveContains("660C") {
            return 1800...20000
        }
        return 2700...6500
    }

    static func intensityStep(for name: String) -> Double {
        if name.localizedCaseInsensitiveContains("660C") {
            return 0.1
        }
        return 1.0
    }
}
