import AppKit

/// The folder picker for a profile's library — Settings' Change…, the
/// first-run prompt and New Profile all choose through here.
enum LibraryFolderPanel {
    /// Runs the panel and returns the chosen folder's path, or `nil` on cancel.
    /// `near` opens the panel beside that folder rather than wherever the last
    /// panel was, which could be inside another profile's library. The choice
    /// is remembered through `access`.
    static func choose(
        title: String, message: String? = nil, near path: String? = nil, access: any FileAccess
    ) -> String? {
        let start = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).deletingLastPathComponent() }
        return GrantingPanel.chooseFolder(
            title: title,
            message: message,
            startingAt: start ?? URL(fileURLWithPath: FileAccessPath.realHome, isDirectory: true),
            access: access
        )
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
