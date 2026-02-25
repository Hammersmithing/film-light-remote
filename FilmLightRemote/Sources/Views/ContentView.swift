import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject private var bridgeManager = BridgeManager.shared

    var body: some View {
        if bridgeManager.isConnected {
            TabView {
                MyLightsView()
                    .tabItem { Label("Lights", systemImage: "lightbulb.2") }
                CuesView()
                    .tabItem { Label("Cues", systemImage: "list.number") }
            }
        } else {
            BridgeConnectionView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BLEManager())
}
