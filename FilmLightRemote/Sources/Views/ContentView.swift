import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject private var bridgeManager = BridgeManager.shared

    var body: some View {
        TabView {
            MyLightsView()
                .tabItem { Label("Lights", systemImage: "lightbulb.2") }
            GroupsView()
                .tabItem { Label("Groups", systemImage: "rectangle.3.group") }
            CuesView()
                .tabItem { Label("Cues", systemImage: "list.number") }
        }
        .overlay(alignment: .top) {
            if bridgeManager.isConnected {
                bridgeBanner(text: "Bridge Connected", color: .green)
            }
        }
    }

    private func bridgeBanner(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(8)
            .padding(.top, 2)
    }
}

#Preview {
    ContentView()
        .environmentObject(BLEManager())
}
