import SwiftUI
import CoreBluetooth

/// Guided "Add Light" wizard presented as a full-screen cover.
struct AddLightFlowView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss

    /// Called when a new light is saved so the caller can refresh its list
    var onComplete: () -> Void

    // MARK: - Step Machine

    enum Step {
        case scanning
        case found
        case provisioning
        case configuring
        case naming
        case complete
        case failed(String)
    }

    @State private var step: Step = .scanning
    @State private var selectedLight: DiscoveredLight?
    @State private var lightName: String = ""
    @StateObject private var provisioningManager = ProvisioningManager()
    @State private var provisionedAddress: UInt16 = 0
    @State private var provisionedDeviceKey: [UInt8]?
    @State private var configTimer: Timer?

    var body: some View {
        NavigationStack {
            VStack {
                stepContent
            }
            .navigationTitle("Add Light")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        cleanup()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            startScanning()
        }
        .onDisappear {
            bleManager.stopScanning()
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .scanning:
            scanningView
        case .found:
            foundView
        case .provisioning:
            provisioningView
        case .configuring:
            configuringView
        case .naming:
            namingView
        case .complete:
            completeView
        case .failed(let msg):
            failedView(message: msg)
        }
    }

    // MARK: - Step 1: Scanning

    private var scanningView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Looking for lights...")
                .font(.headline)
            Text("Make sure your light is powered on and in pairing mode (factory reset).")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Show discovered unprovisioned lights as they appear
            let unprovisioned = bleManager.discoveredLights.filter { $0.meshState == .unprovisioned }
            if !unprovisioned.isEmpty {
                List(unprovisioned) { light in
                    Button {
                        selectedLight = light
                        lightName = light.name
                        step = .found
                    } label: {
                        HStack {
                            Image(systemName: "lightbulb.fill")
                                .foregroundColor(.yellow)
                            VStack(alignment: .leading) {
                                Text(light.name)
                                    .font(.body)
                                Text("Signal: \(light.rssi) dBm")
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
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Step 2: Found / Confirm

    private var foundView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lightbulb.fill")
                .font(.system(size: 70))
                .foregroundColor(.yellow)

            Text(selectedLight?.name ?? "Light")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Ready to add this light to your network. This will take a few seconds.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button {
                startProvisioning()
            } label: {
                Text("Add This Light")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Step 3: Provisioning

    private var provisioningView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView(value: provisioningManager.state.progress)
                .progressViewStyle(LinearProgressViewStyle())
                .padding(.horizontal, 40)

            Text("Setting up light...")
                .font(.headline)

            Text(provisioningManager.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                stepIndicator("Key Exchange", done: provisioningManager.state.progress >= 0.55)
                stepIndicator("Authentication", done: provisioningManager.state.progress >= 0.7)
                stepIndicator("Configuration", done: provisioningManager.state.progress >= 0.95)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Step 4: Configuring (post-provision reconnect + mesh config)

    private var configuringView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Configuring light...")
                .font(.headline)
            Text("Reconnecting and setting up mesh network bindings.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
    }

    // MARK: - Step 5: Naming

    private var namingView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "pencil.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Name Your Light")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Light name", text: $lightName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)

            Button {
                saveLight()
            } label: {
                Text("Save")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(lightName.isEmpty ? Color.gray : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
            .disabled(lightName.isEmpty)

            Spacer()
        }
    }

    // MARK: - Step 6: Complete

    private var completeView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 70))
                .foregroundColor(.green)

            Text("Light Added!")
                .font(.title2)
                .fontWeight(.semibold)

            Text("\(lightName) is ready to use.")
                .font(.body)
                .foregroundColor(.secondary)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("Something Went Wrong")
                .font(.title3)
                .fontWeight(.semibold)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button("Cancel") {
                    cleanup()
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray5))
                .foregroundColor(.primary)
                .cornerRadius(12)

                Button("Retry") {
                    step = .scanning
                    startScanning()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    // MARK: - Helpers

    private func stepIndicator(_ title: String, done: Bool) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(done ? .green : .secondary)
            Text(title)
                .foregroundColor(done ? .primary : .secondary)
            Spacer()
        }
    }

    // MARK: - Actions

    private func startScanning() {
        bleManager.discoveredLights.removeAll()
        bleManager.startScanning()
    }

    private func startProvisioning() {
        guard let light = selectedLight else { return }
        step = .provisioning
        bleManager.stopScanning()

        let keyStorage = KeyStorage.shared
        provisioningManager.networkKey = keyStorage.getNetworkKeyOrDefault()
        provisioningManager.appKey = keyStorage.getAppKeyOrDefault()
        provisioningManager.ivIndex = keyStorage.ivIndex
        let address = keyStorage.allocateUnicastAddress()
        provisioningManager.unicastAddress = address
        provisionedAddress = address
        bleManager.targetUnicastAddress = address

        provisioningManager.startProvisioning(
            peripheral: light.peripheral,
            centralManager: bleManager.centralManager
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let key):
                    provisionedDeviceKey = key
                    KeyStorage.shared.storeDeviceKey(key, forAddress: provisionedAddress)
                    MeshCrypto.reinitialize()
                    // Move to configuring — wait for light to reboot then auto-config happens in BLEManager
                    step = .configuring
                    waitForConfigCompletion()

                case .failure(let error):
                    step = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// After provisioning, the light reboots and advertises as proxy (0x1828).
    /// We scan, connect, and BLEManager's auto-config handles the rest.
    /// After a timeout, proceed to naming regardless (config may complete in background).
    private func waitForConfigCompletion() {
        // Disconnect from the provisioning connection — the light will reboot
        bleManager.disconnect()

        // Short delay for reboot, then scan for proxy
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard let light = selectedLight else {
                step = .naming
                return
            }
            bleManager.connectToKnownPeripheral(identifier: light.peripheral.identifier)
        }

        // Move to naming after reasonable timeout whether config completes or not
        configTimer?.invalidate()
        configTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { _ in
            DispatchQueue.main.async {
                if case .configuring = step {
                    bleManager.disconnect()
                    step = .naming
                }
            }
        }

        // Also watch for config completion
        observeConfigCompletion()
    }

    private func observeConfigCompletion() {
        // Poll config manager state
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if bleManager.configManager.state == .complete {
                timer.invalidate()
                configTimer?.invalidate()
                DispatchQueue.main.async {
                    bleManager.disconnect()
                    step = .naming
                }
            }
        }
    }

    private func saveLight() {
        guard let light = selectedLight else { return }

        let saved = SavedLight(
            name: lightName,
            unicastAddress: provisionedAddress,
            lightType: light.name.contains("Amaran") ? "Amaran" : "Aputure Light",
            peripheralIdentifier: light.peripheral.identifier
        )
        KeyStorage.shared.addSavedLight(saved)
        BridgeManager.shared.addLight(saved)
        onComplete()
        step = .complete
    }

    private func cleanup() {
        bleManager.stopScanning()
        configTimer?.invalidate()
    }
}
