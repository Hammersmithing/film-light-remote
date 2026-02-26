import SwiftUI

/// Shown when the bridge is not connected. Discovers bridges and lets the user connect.
struct BridgeConnectionView: View {
    @ObservedObject private var bridgeManager = BridgeManager.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if let error = bridgeManager.lastError {
                    // Error state
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 60))
                        .foregroundColor(.red)

                    Text("Connection Error")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("Retry") {
                        bridgeManager.lastError = nil
                        bridgeManager.startDiscovery()
                        if let host = bridgeManager.lastBridgeHost {
                            bridgeManager.connect(to: host)
                        }
                    }
                    .buttonStyle(.borderedProminent)

                } else if bridgeManager.discoveredBridges.isEmpty {
                    // Searching
                    ProgressView()
                        .scaleEffect(1.5)

                    Text("Searching for bridge...")
                        .font(.headline)

                    Text("Make sure the ESP32 bridge is powered on and connected to your WiFi network.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                } else {
                    // Bridge list
                    Image(systemName: "wifi.router")
                        .font(.system(size: 50))
                        .foregroundColor(.accentColor)

                    Text("Select Bridge")
                        .font(.title2)
                        .fontWeight(.semibold)

                    List(bridgeManager.discoveredBridges) { bridge in
                        Button {
                            bridgeManager.connectToBridge(bridge)
                        } label: {
                            HStack {
                                Image(systemName: "wifi.router.fill")
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading) {
                                    Text(bridge.name)
                                        .font(.body)
                                    Text(bridge.host)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: 200)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Film Light Remote")
        }
    }
}
