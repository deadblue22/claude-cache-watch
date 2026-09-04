import SwiftUI

@main
struct ClaudeCacheWatchApp: App {
    @StateObject private var model = CacheWatchModel()

    var body: some Scene {
        Window("Claude Cache Watch", id: "main") {
            CachePanel(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
