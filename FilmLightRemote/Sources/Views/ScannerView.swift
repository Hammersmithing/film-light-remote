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
            VStack(spacing: 0) {
                // Scan mode toggle
                Toggle("Show all BLE devices", isOn: $bleManager.scanAllDevices)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .onChange(of: bleManager.scanAllDevices) { _ in
                        // Restart scan with new filter
                        if bleManager.connectionState == .scanning {
                            bleManager.stopScanning()
                            bleManager.startScanning()
                        }
                    }

                Divider()

                if bleManager.connectionState == .scanning {
                    ProgressView()
                        .padding(.top)
                    Text("Scanning for lights...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    Text(bleManager.scanAllDevices
                        ? "Showing all BLE devices"
                        : "Filtering: 0x1827 (unprovisioned) + 0x1828 (provisioned)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if bleManager.discoveredLights.isEmpty && bleManager.connectionState != .scanning {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "light.beacon.max")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("No mesh lights found")
                            .font(.headline)
                        Text("Factory reset your light first:\nhold the reset button until it blinks.\nThen tap Scan.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .padding()
                } else {
                    // Sort: unprovisioned first, then by signal strength
                    let sorted = bleManager.discoveredLights.sorted { a, b in
                        if a.meshState != b.meshState {
                            return a.meshState == .unprovisioned
                        }
                        return a.rssi > b.rssi
                    }

                    List(sorted) { light in
                        Button {
                            if light.meshState == .unprovisioned {
                                // Unprovisioned → go to provisioning
                                lightToProvision = light
                                showProvisioningSheet = true
                            } else {
                                // Provisioned → connect directly
                                bleManager.connect(to: light)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                // Mesh state indicator
                                Circle()
                                    .fill(light.meshState == .unprovisioned ? Color.orange : Color.green)
                                    .frame(width: 10, height: 10)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(light.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)

                                    HStack(spacing: 8) {
                                        Text(light.meshState == .unprovisioned ? "New — tap to provision" : "Provisioned")
                                            .font(.caption)
                                            .foregroundColor(light.meshState == .unprovisioned ? .orange : .green)

                                        Text("RSSI: \(light.rssi) dBm")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    if let uuid = light.deviceUUID {
                                        Text("UUID: \(uuid.uuidString.prefix(18))...")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
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

                            if light.meshState == .unprovisioned {
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
