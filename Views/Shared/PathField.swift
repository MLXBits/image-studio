import SwiftUI

/// A folder setting with Browse…. In the App Store build it's picker-only: a
/// typed path carries no sandbox grant (spec §4), so the path shows read-only,
/// with an × that resets it to the default.
struct PathField: View {
    let placeholder: String
    @Binding var path: String
    let browse: () -> Void
    var onReset: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if BuildFlavor.isAppStore {
                Text(path.isEmpty ? placeholder : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onReset, !path.isEmpty {
                    Button(action: onReset) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.iconButtonCompact)
                    .help("Use the default")
                    .accessibilityLabel("Use the default")
                }
            } else {
                TextField(placeholder, text: $path)
                    .textFieldStyle(.roundedBorder)
            }
            Button("Browse…", action: browse)
        }
    }
}

/// Under a field that takes either a Hugging Face repo ID or a local folder:
/// says when the folder typed there can't be opened. Only the App Store build
/// can fail this way: a typed path has no grant until it's chosen with the
/// field's button. The DMG's FileAccess reaches everything, so it never shows.
struct GrantHint: View {
    @Environment(AppSettings.self) private var settings
    let path: String
    var remedy = "Choose it with Browse… to give access."

    var body: some View {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if FileAccessPath.isLocal(trimmed), !settings.fileAccess.canReach(trimmed) {
            Label("The app can't open this folder. \(remedy)", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
