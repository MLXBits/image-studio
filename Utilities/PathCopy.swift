import AppKit
import SwiftUI

/// Helpers for the "Copy Path" context-menu action: computing an image path relative to the
/// output directory, and writing a string to the pasteboard.
enum PathCopy {
    /// Returns `path` relative to `base` when `path` is under `base`; otherwise returns `path`
    /// unchanged, so a file outside the output dir still yields a usable absolute path.
    static func relative(_ path: String, to base: String) -> String {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let prefix = trimmedBase + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    /// Writes `string` to the general pasteboard, replacing prior contents.
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Shared "Copy Path" submenu for image context menus. Copies `path` relative to the output
/// directory (Relative) or as-is (Absolute); the image file, never the sidecar.
struct CopyPathMenu: View {
    let path: String
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Menu("Copy Path") {
            Button("Relative") { PathCopy.copy(PathCopy.relative(path, to: settings.outputDir)) }
            Button("Absolute") { PathCopy.copy(path) }
        }
    }
}
