import SwiftUI

/// Shown on first launch to let the user choose an output directory
/// without forcing a location (avoids accidental iCloud sync via ~/Pictures).
struct OutputDirectoryPromptView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var profiles
    @Binding var isPresented: Bool
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 6) {
                Text("Where should MLXBits Image Studio save your images?")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(
                    "Choose any folder you control. Avoid iCloud-synced folders like ~/Pictures"
                        + " or ~/Documents if you don't want generated images uploaded to iCloud."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                if settings.outputDir.isEmpty {
                    Text("No folder selected")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(settings.outputDir)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Choose Folder…") {
                    pickFolder()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Choose output folder")
                .accessibilityHint("Opens a folder picker. Generated images will be saved here.")
            }

            HStack(spacing: 12) {
                Button("Skip for Now") {
                    // Use a safe non-iCloud default so the app is functional
                    let home = NSHomeDirectory()
                    error = profiles.changeActiveLibrary(
                        to: "\(home)/MLXBits Image Studio", createIfMissing: true
                    )?.message
                    if error == nil {
                        isPresented = false
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Skip folder selection")
                .accessibilityHint("Saves to ~/MLXBits Image Studio — not inside Pictures or Documents")

                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(settings.outputDir.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 400)
    }

    private func pickFolder() {
        guard let path = LibraryFolderPanel.choose(
            title: "Choose Output Folder",
            message: "Generated images will be saved here. Avoid iCloud-synced folders unless you want cloud backup.",
            near: settings.outputDir
        ) else { return }
        error = profiles.changeActiveLibrary(to: path)?.message
    }
}
