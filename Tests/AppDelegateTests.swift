import AppKit
@testable import MLXBits_Image_Studio
import Testing

/// Closing the main window must not quit the app: queued jobs and downloads keep
/// running, and Window ▸ MLXBits Image Studio reopens it (App Review, guideline 4).
struct AppDelegateTests {
    @Test func closingTheLastWindowKeepsTheAppRunning() {
        #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
