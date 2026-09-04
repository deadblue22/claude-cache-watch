import AppKit
import SwiftUI

@main
struct ClaudeCacheWatchApp: App {
    @StateObject private var model = CacheWatchModel()

    init() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApplication.shared.applicationIconImage = icon
    }

    var body: some Scene {
        Window("Claude Cache Watch", id: "main") {
            CachePanel(model: model)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}
