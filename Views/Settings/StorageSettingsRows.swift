import SwiftUI

/// Settings ▸ Advanced ▸ HuggingFace: where models and mflux's converted
/// weights live. Picker-only in the App Store build, where empty means inside
/// the app's container (spec §4).
struct StorageSettingsRows: View {
    @Environment(AppSettings.self) private var settings

    private var placeholder: String {
        BuildFlavor.isAppStore ? "Inside the app (default)" : ""
    }

    var body: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 4) {
            PathField(
                placeholder: placeholder, path: $s.hfHome,
                browse: { chooseFolder(for: \.hfHome, title: "Choose Models Folder", start: modelsStart) },
                onReset: { s.hfHome = "" }
            )
            Text(BuildFlavor.isAppStore
                ? "Where models are downloaded. Choose your Hugging Face cache (~/.cache/huggingface) "
                + "to share models with other tools."
                : "Where HuggingFace caches downloaded model files. Default: ~/.cache/huggingface")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)

        VStack(alignment: .leading, spacing: 4) {
            PathField(
                placeholder: placeholder, path: $s.mfluxCacheDir,
                browse: { chooseFolder(for: \.mfluxCacheDir, title: "Choose mflux Cache Directory", start: nil) },
                onReset: { s.mfluxCacheDir = "" }
            )
            Text(BuildFlavor.isAppStore
                ? "Where mflux stores converted weight files."
                : "Where mflux stores converted weight files. Default: ~/Library/Caches/mflux")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// The current models folder, or the person's Hugging Face cache when there is one.
    private var modelsStart: URL? {
        settings.hfHome.isEmpty
            ? FileAccessPath.existingHuggingFaceCache()
            : URL(fileURLWithPath: settings.hfHome, isDirectory: true)
    }

    private func chooseFolder(for field: ReferenceWritableKeyPath<AppSettings, String>, title: String, start: URL?) {
        if let path = GrantingPanel.chooseFolder(
            title: title, startingAt: start, showsHiddenFiles: start != nil, access: settings.fileAccess
        ) {
            settings[keyPath: field] = path
        }
    }
}
