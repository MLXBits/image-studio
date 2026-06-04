import SwiftUI

/// Shown on first launch to let the user choose an output directory
/// without forcing a location (avoids accidental iCloud sync via ~/Pictures).
struct OutputDirectoryPromptView: View {
    @Environment(AppSettings.self) private var settings
    @Binding var isPresented: Bool

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
                    settings.outputDir = "\(home)/MLXBits Image Studio"
                    isPresented = false
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose Output Folder"
        panel.message = "Generated images will be saved here. Avoid iCloud-synced folders unless you want cloud backup."
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDir = url.path
        }
    }
}
