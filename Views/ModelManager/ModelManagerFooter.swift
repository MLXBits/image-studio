import AppKit
import SwiftUI

/// The Models window sidebar's footer: how much the listed models take on disk, and a Finder shortcut.
struct ModelManagerFooter: View {
    private static func tilde(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    let hubDir: URL
    /// Where old mflux-save copies live; part of the total when a model still loads from one.
    let savedDir: URL
    let bytes: Int64

    var body: some View {
        HStack(spacing: 6) {
            Text(String(format: "%.1f GB on disk", Double(bytes) / 1_073_741_824))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Models in \(Self.tilde(hubDir)), and older copies in \(Self.tilde(savedDir))")
            Spacer(minLength: 4)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([hubDir])
            } label: {
                Image(systemName: "folder").font(.caption)
            }
            .buttonStyle(.iconButtonCompact)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}
