import SwiftUI

@main
struct TrackpadPenApp: App {
    @StateObject private var engine = PressureEngine()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(engine)
        } label: {
            Image(systemName: engine.isRunning ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
