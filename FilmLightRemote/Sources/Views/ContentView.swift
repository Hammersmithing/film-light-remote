import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    @StateObject private var lightState = LightState()
    @State private var showingScanner = false
    @State private var showingDebugLog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Connection status header
                ConnectionStatusBar()

                if bleManager.connectedLight != nil {
                    // Main control interface
                    LightControlView(lightState: lightState)
                } else {
                    // Not connected view
                    NotConnectedView(showingScanner: $showingScanner)
                }
            }
            .navigationTitle("Film Light Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingDebugLog.toggle()
                    } label: {
                        Image(systemName: "terminal")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if bleManager.connectedLight != nil {
                        Button("Disconnect") {
                            bleManager.disconnect()
                        }
                        .foregroundColor(.red)
                    } else {
                        Button {
                            showingScanner = true
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingScanner) {
                ScannerView()
            }
            .sheet(isPresented: $showingDebugLog) {
                DebugLogView()
            }
        }
    }
}

// MARK: - Connection Status Bar
struct ConnectionStatusBar: View {
    @EnvironmentObject var bleManager: BLEManager

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            Text(statusText)
                .font(.caption)

            Spacer()

            if let light = bleManager.connectedLight {
                Text(light.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    private var statusColor: Color {
        switch bleManager.connectionState {
        case .connected, .ready: return .green
        case .connecting, .discoveringServices, .scanning: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch bleManager.connectionState {
        case .connected: return "Connected"
        case .ready: return "Ready"
        case .connecting: return "Connecting..."
        case .discoveringServices: return "Discovering services..."
        case .scanning: return "Scanning..."
        case .disconnected: return "Disconnected"
        case .failed(let error): return "Failed: \(error)"
        }
    }
}

// MARK: - Not Connected View
struct NotConnectedView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Binding var showingScanner: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lightbulb.slash")
                .font(.system(size: 80))
                .foregroundColor(.secondary)

            Text("No Light Connected")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Scan for nearby Aputure lights to get started")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                showingScanner = true
            } label: {
                Label("Scan for Lights", systemImage: "antenna.radiowaves.left.and.right")
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
}

#Preview {
    ContentView()
        .environmentObject(BLEManager())
}
