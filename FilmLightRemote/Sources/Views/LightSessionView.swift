import SwiftUI

/// Presented as a fullScreenCover when the user taps a saved light.
/// Connects via the bridge (if available) or direct BLE, then shows LightControlView.
struct LightSessionView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss
    @StateObject private var lightState = LightState()
    @ObservedObject private var bridgeManager = BridgeManager.shared

    let savedLight: SavedLight

    private var usingBridge: Bool { bridgeManager.isConnected }

    private var isLightConnected: Bool {
        if usingBridge {
            return bridgeManager.lightStatuses[savedLight.unicastAddress] == true
        } else {
            return bleManager.connectionState == .ready
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLightConnected {
                    LightControlView(lightState: lightState, cctRange: Self.cctRange(for: savedLight.name), intensityStep: Self.intensityStep(for: savedLight.name))
                } else if usingBridge, let error = bridgeManager.lastError {
                    failedView(message: error)
                } else if case .failed(let msg) = bleManager.connectionState {
                    failedView(message: msg)
                } else {
                    connectingView
                }
            }
            .navigationTitle(savedLight.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        if !usingBridge {
                            bleManager.disconnect()
                        }
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            lightState.load(forLightId: savedLight.id)
            bleManager.syncState(from: lightState)
            bleManager.targetUnicastAddress = savedLight.unicastAddress
            if usingBridge {
                bridgeManager.connectLight(unicast: savedLight.unicastAddress)
            } else {
                bleManager.connectToKnownPeripheral(identifier: savedLight.peripheralIdentifier)
            }
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
            Text(usingBridge ? "Via bridge" : "Via Bluetooth")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: usingBridge ? "wifi.exclamationmark" : "antenna.radiowaves.left.and.right.slash")
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
                if usingBridge {
                    bridgeManager.connectLight(unicast: savedLight.unicastAddress)
                } else {
                    bleManager.connectToKnownPeripheral(identifier: savedLight.peripheralIdentifier)
                }
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
