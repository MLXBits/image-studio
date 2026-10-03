import AppKit

/// The folder picker for a profile's library — Settings' Change…, the
/// first-run prompt and New Profile all choose through here.
enum LibraryFolderPanel {
    /// Runs the panel and returns the chosen folder's path, or `nil` on cancel.
    /// `near` opens the panel beside that folder rather than wherever the last
    /// panel was, which could be inside another profile's library.
    static func choose(title: String, message: String? = nil, near path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.prompt = "Choose"
        if let message {
            panel.message = message
        }
        let start = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).deletingLastPathComponent() }
        panel.directoryURL = start ?? FileManager.default.homeDirectoryForCurrentUser
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

extension NSOpenPanel {
    /// Opens the panel in the active profile's library. Otherwise macOS reopens
    /// wherever the last panel was — after a switch, inside another profile's
    /// library.
    func startInLibrary(_ path: String) {
        guard !path.isEmpty else { return }
        directoryURL = URL(fileURLWithPath: path, isDirectory: true)
    }
}
