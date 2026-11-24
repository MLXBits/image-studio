import SwiftUI

/// The Models window's pane for a custom checkpoint: a Hugging Face repo or local folder, and
/// the model it loads as. The edits are a draft until **Use**, so typing a repo never changes
/// the main window or evicts its warm model.
struct CustomModelDetailView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelManagerRouter.self) private var router
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    @State private var repo = ""
    @State private var loadsAs: FluxModelVariant = .flux2Klein9B

    /// Models a custom checkpoint can load as: those the installed mflux ships a generation CLI
    /// for. Falls back to every model while mflux is still being installed (nothing detected
    /// yet), and always keeps the draft's target so the picker never renders blank.
    private var targets: [FluxModelVariant] {
        let available = settings.availableModels
        guard !available.isEmpty else { return FluxModelVariant.allModels }
        return available.contains(loadsAs) ? available : available + [loadsAs]
    }

    private var trimmedRepo: String {
        repo.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        ToolDetailLayout(
            title: "Custom",
            blurb: "A fine-tune or other checkpoint in MLX format: a Hugging Face repo ID"
                + " (org/my-fine-tune) or a local folder. It must match the architecture of the"
                + " model it loads as: a Krea 2 fine-tune loads as Krea 2, a FLUX.2 one as a Klein"
                + " variant (most fine-tunes use Klein 9B)."
        ) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("org/repo or /path/to/model", text: $repo)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Custom model repo or path")
                    Button("Choose…") { chooseFolder() }
                        .modelManagerButton()
                        .help("Choose a local model folder")
                }
                GrantHint(path: repo, remedy: "Choose it with Choose… to give access.")
            }
            Picker("Loads as", selection: $loadsAs) {
                ForEach(targets, id: \.self) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .fixedSize()
            .accessibilityHint("Selects the pipeline, params panel and mflux CLI used to run it")
            Text("Only models the installed mflux ships a CLI for are listed.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            useButton
        }
        .onAppear {
            repo = router.mainCustom.repo
            loadsAs = router.mainCustom.loadsAs
        }
    }

    private var useButton: some View {
        let busy = coordinator.activeFamily != nil
        return Button("Use") {
            router.pendingUse = .init(custom: .init(repo: trimmedRepo, loadsAs: loadsAs))
            openWindow(id: MLXBitsImageStudioApp.mainWindowID)
        }
        .modelManagerButton()
        .disabled(busy || trimmedRepo.isEmpty)
        .help(busy ? "Finish or stop the running job first" : "Use this checkpoint in the main window")
    }

    private func chooseFolder() {
        if let path = GrantingPanel.chooseFolder(title: "Choose Model Folder", access: settings.fileAccess) {
            repo = path
        }
    }
}
