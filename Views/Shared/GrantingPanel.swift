import AppKit

/// Open panels whose choice the app keeps access to. Each chosen folder or
/// file is remembered through ``FileAccess`` before its path is returned, so
/// the App Store build reaches it again after a relaunch (spec §4); the DMG's
/// FileAccess ignores the call. Source-image pickers don't need this: those
/// images are copied into the profile (``AppSettings/adoptSourceImage(_:)``).
enum GrantingPanel {
    /// `startingAt` opens the panel *in* that folder. With nothing selected,
    /// Choose picks it — one click for the first-run models step.
    static func chooseFolder(
        title: String,
        message: String? = nil,
        startingAt start: URL? = nil,
        showsHiddenFiles: Bool = false,
        access: any FileAccess
    ) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = showsHiddenFiles
        configure(panel, title: title, message: message, start: start)
        return run(panel, access: access)
    }

    static func chooseFile(
        title: String, message: String? = nil, startingAt start: URL? = nil, access: any FileAccess
    ) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true
        configure(panel, title: title, message: message, start: start)
        return run(panel, access: access)
    }

    private static func configure(_ panel: NSOpenPanel, title: String, message: String?, start: URL?) {
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.prompt = "Choose"
        if let message {
            panel.message = message
        }
        if let start {
            panel.directoryURL = start
        }
    }

    private static func run(_ panel: NSOpenPanel, access: any FileAccess) -> String? {
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        access.remember(url)
        return url.path
    }
}
