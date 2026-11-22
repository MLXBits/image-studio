import AppKit
import SwiftUI

/// The Models window sidebar's footer: how much the listed repos take on disk, and a Finder shortcut.
struct ModelManagerFooter: View {
    let hubDir: URL
    let bytes: Int64

    var body: some View {
        HStack(spacing: 6) {
            Text(summary)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
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

    private var summary: String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824) + " in " + (hubDir.path as NSString).abbreviatingWithTildeInPath
    }
}
