import AppKit

/// AppKit hooks SwiftUI doesn't expose.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the main window doesn't quit: queued jobs and model downloads keep
    /// running, and Window ▸ MLXBits Image Studio reopens it (App Review, guideline 4).
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
