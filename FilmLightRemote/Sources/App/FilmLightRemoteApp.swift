import SwiftUI

@main
struct FilmLightRemoteApp: App {
    @StateObject private var bleManager = BLEManager()
    private let bridgeManager = BridgeManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .onAppear {
                    bridgeManager.startDiscovery()
                    // If we have a remembered bridge but no mDNS match yet, try direct connect
                    if let host = bridgeManager.lastBridgeHost, !bridgeManager.isConnected {
                        bridgeManager.connect(to: host)
                    }
                }
        }
    }
}
