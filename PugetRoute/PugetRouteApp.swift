import SwiftUI

@main
struct PugetRouteApp: App {
    /// Watching scenePhase here lets us flush the elevation cache to disk
    /// the moment the OS tells us we're going inactive/background. Without
    /// this, a user who plans a trip and immediately backgrounds the app
    /// might lose the last 0–2 s of stamped profiles to the debounce
    /// window. iOS gives ~5 s of background grace which is plenty for one
    /// JSON write but not enough to wait out the debounce.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                Task { await ElevationCache.shared.flushNow() }
            }
        }
    }
}
