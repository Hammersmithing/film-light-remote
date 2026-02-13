import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager

    var body: some View {
        MyLightsView()
    }
}

#Preview {
    ContentView()
        .environmentObject(BLEManager())
}
