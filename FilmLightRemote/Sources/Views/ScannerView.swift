import SwiftUI

struct ScannerView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss

    /// Light selected for provisioning
    @State private var lightToProvision: DiscoveredLight?

    /// Whether provisioning sheet is shown
    @State private var showProvisioningSheet = false

    var body: some View {
        NavigationStack {
            VStack {
                if bleManager.connectionState == .scanning {
                    ProgressView()
                        .padding()
                    Text("Scanning for lights...")
                        .foregroundColor(.secondary)
                }

                if bleManager.discoveredLights.isEmpty && bleManager.connectionState != .scanning {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("No lights found")
                            .font(.headline)
                        Text("Make sure your light is powered on and in range")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .padding()
                } else {
                    // Sort by signal strength (strongest first)
                    List(bleManager.discoveredLights.sorted { $0.rssi > $1.rssi }) { light in
                        Button {
                            bleManager.connect(to: light)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(light.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text("RSSI: \(light.rssi) dBm")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: signalStrengthIcon(rssi: light.rssi))
                                    .foregroundColor(signalStrengthColor(rssi: light.rssi))
                            }
                        }
                        .contextMenu {
                            Button {
                                bleManager.connect(to: light)
                                dismiss()
                            } label: {
                                Label("Connect", systemImage: "link")
                            }

                            Button {
                                lightToProvision = light
                                showProvisioningSheet = true
                            } label: {
                                Label("Provision Device", systemImage: "key.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scan for Lights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        bleManager.stopScanning()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if bleManager.connectionState == .scanning {
                        Button("Stop") {
                            bleManager.stopScanning()
                        }
                    } else {
                        Button("Scan") {
                            bleManager.startScanning()
                        }
                        .disabled(!bleManager.isBluetoothAvailable)
                    }
                }
            }
            .onAppear {
                if bleManager.isBluetoothAvailable {
                    bleManager.startScanning()
                }
            }
            .onDisappear {
                bleManager.stopScanning()
            }
            .sheet(isPresented: $showProvisioningSheet) {
                if let light = lightToProvision {
                    ProvisioningView(light: light)
                        .environmentObject(bleManager)
                }
            }
        }
    }

    private func signalStrengthIcon(rssi: Int) -> String {
        switch rssi {
        case -50...0: return "wifi"
        case -70..<(-50): return "wifi"
        case -90..<(-70): return "wifi"
        default: return "wifi.slash"
        }
    }

    private func signalStrengthColor(rssi: Int) -> Color {
        switch rssi {
        case -50...0: return .green
        case -70..<(-50): return .orange
        case -90..<(-70): return .red
        default: return .gray
        }
    }
}

#Preview {
    ScannerView()
        .environmentObject(BLEManager())
}
