import SwiftUI
import CoreBluetooth

/// View for provisioning an unprovisioned Bluetooth Mesh device
struct ProvisioningView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss

    /// The light to provision
    let light: DiscoveredLight

    /// Provisioning manager instance
    @StateObject private var provisioningManager = ProvisioningManager()

    /// Whether provisioning is in progress
    @State private var isProvisioning = false

    /// Error message to display
    @State private var errorMessage: String?

    /// Device key received after successful provisioning
    @State private var deviceKey: [UInt8]?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Device info
                VStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.yellow)

                    Text(light.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("RSSI: \(light.rssi) dBm")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)

                // State content
                if let deviceKey = deviceKey {
                    successView(deviceKey: deviceKey)
                } else if let error = errorMessage {
                    failureView(error: error)
                } else if isProvisioning {
                    progressView
                } else {
                    startView
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Provision Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        if isProvisioning {
                            provisioningManager.cancel()
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Views

    private var startView: some View {
        VStack(spacing: 16) {
            Text("This device needs to be provisioned before it can be controlled.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Text("Provisioning will configure the device with network credentials so it can communicate securely.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Button(action: startProvisioning) {
                HStack {
                    Image(systemName: "key.fill")
                    Text("Start Provisioning")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .padding(.top, 16)
        }
    }

    private var progressView: some View {
        VStack(spacing: 20) {
            ProgressView(value: provisioningManager.state.progress)
                .progressViewStyle(LinearProgressViewStyle())
                .padding(.horizontal)

            Text(provisioningManager.state.description)
                .font(.headline)

            Text(provisioningManager.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Step indicators
            VStack(alignment: .leading, spacing: 8) {
                stepRow("Key Exchange", completed: provisioningManager.state.progress >= 0.55)
                stepRow("Authentication", completed: provisioningManager.state.progress >= 0.7)
                stepRow("Data Transfer", completed: provisioningManager.state.progress >= 0.95)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    private func successView(deviceKey: [UInt8]) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Provisioning Complete")
                .font(.headline)

            Text("The device has been successfully configured and is ready for use.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Device Key:")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(deviceKey.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ") + "...")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .cornerRadius(8)

            Button("Done") {
                dismiss()
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }

    private func failureView(error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("Provisioning Failed")
                .font(.headline)

            Text(error)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray5))
                .foregroundColor(.primary)
                .cornerRadius(12)

                Button("Retry") {
                    errorMessage = nil
                    startProvisioning()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
        }
    }

    private func stepRow(_ title: String, completed: Bool) -> some View {
        HStack {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                .foregroundColor(completed ? .green : .secondary)
            Text(title)
                .foregroundColor(completed ? .primary : .secondary)
            Spacer()
        }
    }

    // MARK: - Actions

    private func startProvisioning() {
        isProvisioning = true

        // Configure with stored or default keys
        let keyStorage = KeyStorage.shared
        provisioningManager.networkKey = keyStorage.getNetworkKeyOrDefault()
        provisioningManager.appKey = keyStorage.getAppKeyOrDefault()
        provisioningManager.ivIndex = keyStorage.ivIndex
        provisioningManager.unicastAddress = keyStorage.allocateUnicastAddress()

        provisioningManager.startProvisioning(
            peripheral: light.peripheral,
            centralManager: bleManager.centralManager
        ) { result in
            DispatchQueue.main.async {
                isProvisioning = false

                switch result {
                case .success(let key):
                    self.deviceKey = key
                    // Store the device key
                    KeyStorage.shared.storeDeviceKey(key, forAddress: provisioningManager.unicastAddress)
                    // Reinitialize MeshCrypto with the keys used for provisioning
                    MeshCrypto.reinitialize()

                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// Preview disabled — DiscoveredLight requires a real CBPeripheral
