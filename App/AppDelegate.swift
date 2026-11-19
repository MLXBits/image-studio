import AppKit

/// AppKit hooks SwiftUI doesn't expose.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether a generation is running. The app sets it once its stores exist;
    /// until then nothing can be running.
    var isGenerating: () -> Bool = { false }

    func applicationWillFinishLaunching(_: Notification) {
        // Writes to a dead subprocess's stdin must return EPIPE so the catch runs, instead of killing the app.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Closing the main window doesn't quit: queued jobs and model downloads keep
    /// running, and Window ▸ MLXBits Image Studio reopens it (App Review, guideline 4).
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Quitting mid-generation throws the run away, so ask first. ⌘Q is the only
    /// way out, since closing the window keeps the app running.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard isGenerating() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while an image is generating?"
        alert.informativeText = "Quitting stops the current generation."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
