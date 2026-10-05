import SwiftUI

/// The App Store build's first-run models step (spec §4). It offers the
/// person's Hugging Face cache when there is one; otherwise models stay in the
/// app's container, and Settings ▸ Advanced can move them later.
struct ModelsFolderStepView: View {
    /// Set once this step is answered, so it's shown on one launch only.
    static let doneKey = "firstRun.modelsFolderStepDone"

    @Environment(AppSettings.self) private var settings
    let onDone: () -> Void
    private let existingCache = FileAccessPath.existingHuggingFaceCache()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 6) {
                Text(existingCache == nil
                    ? "Where should models be stored?"
                    : "We found your Hugging Face model cache — use it?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let existingCache {
                    Text(existingCache.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            HStack(spacing: 12) {
                Button(existingCache == nil ? "Continue" : "Keep Models in the App") { onDone() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button(existingCache == nil ? "Choose Folder…" : "Use It…") { choose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 400)
    }

    private var explanation: String {
        existingCache == nil
            ? "Models download into the app's own storage. To keep them on another drive, choose a folder. "
            + "You can change this later in Settings ▸ Advanced."
            : "Models you've already downloaded with other tools are reused instead of downloaded again. "
            + "Click Choose in the next window to give the app access."
    }

    private func choose() {
        guard let path = GrantingPanel.chooseFolder(
            title: existingCache == nil ? "Choose Models Folder" : "Use Hugging Face Cache",
            message: existingCache == nil ? "Models will be downloaded here." : "Click Choose to use this folder for models.",
            startingAt: existingCache,
            showsHiddenFiles: existingCache != nil,
            access: settings.fileAccess
        ) else { return }
        settings.hfHome = path
        onDone()
    }
}
