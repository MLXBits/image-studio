import SwiftUI

/// Shown under the top bar while the active profile's library folder is
/// missing — usually an unplugged drive. Generations fail until it's back.
struct MissingLibraryBanner: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppSettings.self) private var settings
    @State private var error: String?

    var body: some View {
        if profiles.isLibraryMissing {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(error ?? message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Reconnect the drive it's on, or choose the folder (again) for this profile.")
                Spacer()
                Button("Retry") { profiles.refreshLibraryAvailability() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Button("Change Folder…") { changeFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(profiles.switchBlockReason != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var message: String {
        profiles.libraryStatus == .noAccess
            ? "Choose the library folder again to give the app access: \(settings.outputDir)"
            : "Library folder not found: \(settings.outputDir)"
    }

    private func changeFolder() {
        guard let path = LibraryFolderPanel.choose(
            title: "Choose Library Folder",
            message: "Images for “\(profiles.activeProfile?.name ?? "")” will be saved here.",
            near: settings.outputDir,
            access: profiles.fileAccess
        ) else { return }
        error = profiles.changeActiveLibrary(to: path)?.message
    }
}
