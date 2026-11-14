import SwiftUI

/// Qwen-Image 2.1 Turbo submission form. Generate is text-to-image; Edit adds an
/// ordered list of up to ten reference images, with the output sized from them
/// unless a size is chosen. Turbo is guidance-free, so there is no guidance or
/// negative prompt, and no img2img: an edit starts from noise.
struct Qwen21ParamsPanelView: View {
    @Bindable var params: Qwen21ParamsPanelState
    /// Forwarded from ContentView — turns scenario-generated prompts into one job each.
    var onQueueScenarioBatch: ([String]) -> Void = { _ in }
    @Environment(AppSettings.self) private var settings
    @Environment(GalleryStore.self) private var gallery
    @Environment(TimingStore.self) private var timing
    @Environment(LoraLibraryStore.self) private var loraLibrary

    @StateObject private var clipboardMonitor =
        ClipboardImageMonitor(imageExtensions: ["png", "jpg", "jpeg", "webp"])

    private var showsSizePicker: Bool {
        !(params.isEditMode && params.matchReferenceSize)
    }

    private var estimate: TimingStore.Estimate? {
        timing.estimate(
            model: "qwen21",
            quantize: params.quantize, lowRam: settings.resolvedDefaults(for: .qwen21Turbo).lowRam,
            steps: params.steps,
            megapixels: Double(params.width * params.height) / 1_000_000
        )
    }

    var body: some View {
        SectionContainerView(
            title: "Generation Mode",
            info: "Generate: an image from the prompt alone.\n\nEdit: change or combine reference "
                + "images by instruction — \"make the jacket green\", or with two images, \"put the "
                + "person from image 1 in the setting of image 2\". Works with one image too."
        ) {
            Picker("", selection: $params.isEditMode) {
                Text("Generate").tag(false)
                Text("Edit").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
        }

        Divider()

        SectionContainerView(
            title: "Prompt",
            info: params.isEditMode
                ? "Describe the edit. Refer to the references as image 1, image 2, … in list order."
                : "Describe the image. Qwen-Image 2.1 Turbo runs 8 steps without guidance.\n\n"
                + "Wildcards: {red|black|white} makes Generate run one job per option "
                + "(up to 10), in order. Smaller groups cycle; a batch count overrides."
        ) {
            GrowingPromptField(
                text: $params.prompt,
                placeholder: params.isEditMode ? "Describe the edit…" : "Describe your image…",
                label: "Prompt",
                hint: params.isEditMode ? "Describe the change to the reference images" : "Describe the image you want to generate",
                tokenSoftCap: FluxModelVariant.qwen21Turbo.promptTokenSoftCap
            )
        } accessory: {
            HStack(spacing: 6) {
                ScenarioGeneratorButton(onSelect: { params.prompt = $0 }, onQueue: onQueueScenarioBatch)
                PromptHistoryButton { params.prompt = $0 }
            }
        }

        if params.isEditMode {
            Divider()
            SectionContainerView(
                title: "Reference Images",
                info: "Up to \(Qwen21Job.maxReferences) images, in the order the prompt refers to them. "
                    + "Drag a row to reorder."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    EditImageListView(
                        paths: $params.editImagePaths, maxCount: Qwen21Job.maxReferences,
                        clipboardHasImage: clipboardMonitor.hasImage, pastePrefix: "pasted-qwen21"
                    )
                    Toggle("Match the size of the last reference", isOn: $params.matchReferenceSize)
                        .font(.caption)
                        .help("Off: generate at the size below instead.")
                }
            }
            .onAppear { clipboardMonitor.start() }
            .onDisappear { clipboardMonitor.stop() }
        }

        Divider()

        SectionContainerView(
            title: "Folder",
            info: "Organizes generated images into named subfolders inside your output "
                + "directory. Leave as Default to keep everything in one place."
        ) {
            FolderComboBox(text: $params.board, options: gallery.boards.filter { $0 != "Default" }, placeholder: "Default")
                .accessibilityLabel("Output group")
        }

        if showsSizePicker {
            Divider()
            SectionContainerView(title: nil, info: nil) {
                DimensionPickerView(width: $params.width, height: $params.height, constraints: .qwen21, estimate: estimate)
            }
        }

        Divider()

        SectionContainerView(title: nil, info: nil) {
            StepsSeedRow(
                steps: $params.steps, seed: $params.seed, model: .qwen21Turbo,
                stepsInfo: "Turbo is distilled for 8 steps; other counts resample the same 8-step "
                    + "schedule. Below about 1024 px, fine detail turns into a pixel grid."
            )
        }

        Divider()

        LoraManagerView(
            loras: $params.loras,
            showAdd: false,
            defaultLoras: loraLibrary.defaultLoras(for: .qwen21),
            modelFamily: .qwen21,
            library: loraLibrary,
            onInsertTriggerWords: { params.prompt = insertTriggerWords($0, into: params.prompt) },
            onReset: { params.loras = loraLibrary.defaultLoras(for: .qwen21) }
        )
        .padding(.bottom, 8)
    }
}
