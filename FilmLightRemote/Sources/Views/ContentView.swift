import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager

    var body: some View {
        TabView {
            MyLightsView()
                .tabItem { Label("Lights", systemImage: "lightbulb.2") }
            CuesView()
                .tabItem { Label("Cues", systemImage: "list.number") }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BLEManager())
}
