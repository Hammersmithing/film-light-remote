import SwiftUI

/// Presented as a fullScreenCover when the user taps a saved light.
/// Reconnects to the peripheral and shows LightControlView when ready.
struct LightSessionView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss
    @StateObject private var lightState = LightState()

    let savedLight: SavedLight

    var body: some View {
        NavigationStack {
            Group {
                switch bleManager.connectionState {
                case .ready, .connected:
                    LightControlView(lightState: lightState)
                case .failed(let msg):
                    failedView(message: msg)
                default:
                    connectingView
                }
            }
            .navigationTitle(savedLight.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        bleManager.disconnect()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            lightState.load(forLightId: savedLight.id)
            bleManager.syncState(from: lightState)
            bleManager.targetUnicastAddress = savedLight.unicastAddress
            bleManager.connectToKnownPeripheral(identifier: savedLight.peripheralIdentifier)
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
                bleManager.connectToKnownPeripheral(identifier: savedLight.peripheralIdentifier)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(10)

            Spacer()
        }
    }
}
