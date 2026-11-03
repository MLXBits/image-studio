import AppKit
import SwiftUI

/// Helpers for the "Copy Path" context-menu action: computing an image path relative to the
/// output directory, and writing a string to the pasteboard.
enum PathCopy {
    /// Returns `path` relative to `base` when `path` is under `base` (both normalized, so `..`
    /// segments can't fake containment); otherwise returns `path` unchanged, so a file outside
    /// the output dir still yields a usable absolute path.
    static func relative(_ path: String, to base: String) -> String {
        let normalizedPath = normalize(path)
        let normalizedBase = normalize(base)
        let prefix = normalizedBase + "/"
        guard normalizedPath.hasPrefix(prefix) else { return path }
        return String(normalizedPath.dropFirst(prefix.count))
    }

    /// Lexically normalizes an absolute path: resolves `.` and `..` segments and removes
    /// trailing slashes, without touching the filesystem.
    private static func normalize(_ path: String) -> String {
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." {
                continue
            }
            if part == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
            } else {
                components.append(String(part))
            }
        }
        return "/" + components.joined(separator: "/")
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
