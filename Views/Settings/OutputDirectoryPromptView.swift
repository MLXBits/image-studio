import SwiftUI

/// Shown on first launch to choose the library folder. Skip for Now uses
/// `~/MLXBits Image Studio` in the DMG (not iCloud-synced), and Pictures in
/// the App Store build, whose sandbox may write there. In the App Store build
/// the models-folder step follows (spec §4).
struct OutputDirectoryPromptView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var profiles
    @AppStorage(ModelsFolderStepView.doneKey) private var modelsFolderStepDone = false
    @Binding var isPresented: Bool
    /// App Store first run: follow the library step with the models step.
    let includeModelsStep: Bool
    @State private var error: String?
    @State private var showingModelsStep: Bool

    var body: some View {
        if showingModelsStep {
            ModelsFolderStepView {
                modelsFolderStepDone = true
                isPresented = false
            }
        } else {
            libraryStep
        }
    }

    private var libraryStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 6) {
                Text("Where should MLXBits Image Studio save your images?")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(BuildFlavor.isAppStore
                    ? "Choose any folder you control, or skip to save into Pictures ▸ MLXBits Image Studio."
                    : "Choose any folder you control. Avoid iCloud-synced folders like ~/Pictures"
                    + " or ~/Documents if you don't want generated images uploaded to iCloud.")
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
                    error = profiles.changeActiveLibrary(
                        to: FileAccessPath.defaultLibrary(isAppStore: BuildFlavor.isAppStore, home: FileAccessPath.realHome),
                        createIfMissing: true
                    )?.message
                    if error == nil {
                        finishLibraryStep()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Skip folder selection")
                .accessibilityHint(BuildFlavor.isAppStore
                    ? "Saves to Pictures ▸ MLXBits Image Studio"
                    : "Saves to ~/MLXBits Image Studio — not inside Pictures or Documents")

                Button("Done") {
                    finishLibraryStep()
                }
                .buttonStyle(.borderedProminent)
                .disabled(settings.outputDir.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 400)
    }

    init(isPresented: Binding<Bool>, includeModelsStep: Bool = false, startAtModelsStep: Bool = false) {
        _isPresented = isPresented
        self.includeModelsStep = includeModelsStep
        _showingModelsStep = State(initialValue: includeModelsStep && startAtModelsStep)
    }

    private func pickFolder() {
        guard let path = LibraryFolderPanel.choose(
            title: "Choose Output Folder",
            message: "Generated images will be saved here. Avoid iCloud-synced folders unless you want cloud backup.",
            near: settings.outputDir,
            access: profiles.fileAccess
        ) else { return }
        error = profiles.changeActiveLibrary(to: path)?.message
    }

    private func finishLibraryStep() {
        if includeModelsStep {
            showingModelsStep = true
        } else {
            isPresented = false
        }
    }
}
