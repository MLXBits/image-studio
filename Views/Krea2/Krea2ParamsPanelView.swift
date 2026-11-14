import AppKit
import SwiftUI

/// Krea 2 Turbo submission form. Turbo text-to-image (+ optional img2img init
/// image): prompt (+ optional negative prompt when CFG is on), dimensions, steps,
/// guidance, seed/batch, LoRA, and output folder. Sampler is fixed (er_sde) and
/// there is no multi-image edit path.
struct Krea2ParamsPanelView: View {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    @Bindable var params: Krea2ParamsPanelState
    /// Forwarded from ContentView — turns scenario-generated prompts into one job each.
    var onQueueScenarioBatch: ([String]) -> Void = { _ in }
    @Environment(AppSettings.self) private var settings
    @Environment(GalleryStore.self) private var gallery
    @Environment(TimingStore.self) private var timing
    @Environment(LoraLibraryStore.self) private var loraLibrary

    @State private var isImageDropTargeted: Bool = false
    @State private var pasteError: String?
    @StateObject private var clipboardMonitor =
        ClipboardImageMonitor(imageExtensions: ["png", "jpg", "jpeg", "webp"])

    private var cfgOn: Bool {
        params.guidance != 1.0
    }

    /// Learned-time estimate for the current Krea 2 configuration. Low-RAM is a
    /// Settings value, so it is read live rather than from the panel state.
    private var estimate: TimingStore.Estimate? {
        timing.estimate(
            model: "krea2",
            quantize: params.quantize, lowRam: settings.resolvedDefaults(for: .krea2).lowRam,
            steps: params.steps,
            megapixels: Double(params.width * params.height) / 1_000_000
        )
    }

    var body: some View {
        SectionContainerView(
            title: "Prompt",
            info: "Describe what you want to generate. Krea 2 Turbo runs at CFG 1.0 by default; "
                + "raise Guidance above 1 to enable the negative prompt and stricter adherence.\n\n"
                + "Wildcards: {red|black|white} makes Generate run one job per option "
                + "(up to 10), in order. Smaller groups cycle; a batch count overrides."
        ) {
            GrowingPromptField(
                text: $params.prompt,
                placeholder: "Describe your image…",
                label: "Prompt",
                hint: "Describe the image you want to generate",
                tokenSoftCap: FluxModelVariant.krea2.promptTokenSoftCap
            )
            if cfgOn {
                GrowingPromptField(
                    text: $params.negativePrompt,
                    placeholder: "Negative prompt (optional)…",
                    label: "Negative prompt",
                    hint: "Describe elements to avoid (only used when Guidance > 1)"
                )
            }
        } accessory: {
            HStack(spacing: 6) {
                ScenarioGeneratorButton(
                    onSelect: { params.prompt = $0 },
                    onQueue: onQueueScenarioBatch
                )
                PromptHistoryButton { params.prompt = $0 }
            }
        }

        Divider()

        SectionContainerView(
            title: "Image Input",
            info: "Optional reference image for image-to-image generation. Drag an image "
                + "here or click to browse. Higher strength = closer to the original image. "
                + "Lower strength = more creative, prompt dominates."
        ) {
            img2ImgSection
        }
        .onAppear { clipboardMonitor.start() }
        .onDisappear { clipboardMonitor.stop() }
        .errorAlert("Could not paste image", message: $pasteError)

        Divider()

        SectionContainerView(
            title: "Folder",
            info: "Organizes generated images into named subfolders inside your output "
                + "directory. Leave as Default to keep everything in one place."
        ) {
            FolderComboBox(
                text: $params.board,
                options: gallery.boards.filter { $0 != "Default" },
                placeholder: "Default"
            )
            .accessibilityLabel("Output group")
            .accessibilityHint("Subfolder name for organizing generated images")
        }

        Divider()

        SectionContainerView(title: nil, info: nil) {
            VStack(alignment: .leading, spacing: 6) {
                DimensionPickerView(
                    width: $params.width, height: $params.height, constraints: .krea2, estimate: estimate
                )
                PidDecodeToggleView(
                    pidDecode: $params.pidDecode, pidDegradeSigma: $params.pidDegradeSigma,
                    width: params.width, height: params.height, family: .krea2
                )
            }
        }

        Divider()

        SectionContainerView(title: nil, info: nil) {
            StepsSeedRow(
                steps: $params.steps, seed: $params.seed, model: .krea2,
                stepsInfo: "Krea 2 Turbo is distilled for 8 steps. More steps add compute "
                    + "with diminishing returns; fewer may reduce quality."
            )
        }

        Divider()

        SectionContainerView(
            title: "Guidance",
            info: "How closely the model follows your prompt. Krea 2 Turbo is tuned for CFG 1.0; "
                + "values above 1 enable classifier-free guidance (and the negative prompt) at the "
                + "cost of a second forward pass per step."
        ) {
            guidanceRow
        }

        Divider()

        LoraManagerView(
            loras: $params.loras,
            showAdd: false,
            defaultLoras: loraLibrary.defaultLoras(for: .krea2),
            modelFamily: .krea2,
            library: loraLibrary,
            onInsertTriggerWords: { params.prompt = insertTriggerWords($0, into: params.prompt) },
            onReset: {
                params.loras = loraLibrary.defaultLoras(for: .krea2)
            }
        )
        .padding(.bottom, 8)
    }

    // MARK: - Guidance

    private var guidanceRow: some View {
        HStack(spacing: 6) {
            Slider(value: $params.guidance, in: 1.0 ... 15.0, step: 0.5)
                .accessibilityLabel("Guidance")
                .accessibilityValue(String(format: "%.1f", params.guidance))
                .accessibilityHint("Higher = follows prompt more strictly. 1.0 = turbo default.")
            Text(String(format: "%.1f", params.guidance))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 28)
        }
    }

    // MARK: - Img2img

    private var img2ImgSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !params.imagePath.isEmpty {
                HStack(spacing: 4) {
                    Spacer()
                    Button {
                        params.imagePath = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.iconButton)
                    .accessibilityLabel("Remove reference image")
                }
            }

            if params.imagePath.isEmpty {
                HStack(spacing: 6) {
                    Button { browseImage() } label: {
                        HStack {
                            Image(systemName: "photo.badge.plus")
                            Text("Choose Image…")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Choose reference image")
                    .accessibilityHint("Opens a file picker to select an image for img2img generation")

                    if clipboardMonitor.hasImage {
                        Button { pasteImage() } label: {
                            Image(systemName: "doc.on.clipboard")
                                .padding(.vertical, 6)
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Paste image from clipboard")
                        .help("Paste image from clipboard")
                    }
                }
            } else {
                HStack(spacing: 8) {
                    if let img = NSImage(contentsOfFile: params.imagePath) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .thumbnailHoverPreview(imagePath: params.imagePath)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: params.imagePath).lastPathComponent)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 4) {
                            Text("Strength").font(.caption2).foregroundStyle(.secondary)
                            InfoButton(
                                title: "Image Strength",
                                description: "How faithfully the output follows the original image."
                                    + " High strength (75–95%) = stays close to the original, subtle"
                                    + " changes. Low strength (15–30%) = more creative freedom, prompt"
                                    + " dominates. Think of it as image preservation, not prompt strength."
                            )
                            Slider(value: $params.imageStrength, in: 0.05 ... 0.95)
                                .onChange(of: params.imageStrength) { _, v in params.imageStrength = round(v / 0.05) * 0.05 }
                                .accessibilityLabel("Image strength")
                                .accessibilityValue(String(format: "%.0f%%", params.imageStrength * 100))
                                .accessibilityHint("How much the reference image influences the output. Lower = more faithful to original.")
                            Text(String(format: "%.0f%%", params.imageStrength * 100))
                                .font(.caption2).monospacedDigit().frame(width: 30)
                        }
                    }
                }
            }
        }
        .imageDropTarget(extensions: Self.imageExtensions, isTargeted: $isImageDropTargeted) { paths in
            guard let path = paths.first else { return }
            params.imagePath = settings.adoptSourceImage(path)
            params.adoptResolvedPromptForImg2Img(at: path)
        }
        .dropHighlight(isImageDropTargeted)
    }

    // MARK: - Img2img helpers

    private func pasteImage() {
        do {
            if let path = try ImagePasteboard.pastedImagePath(tempPrefix: "pasted-krea2", extensions: Self.imageExtensions) {
                params.imagePath = settings.adoptSourceImage(path)
            }
        } catch {
            pasteError = "The pasted image could not be saved: \(error.localizedDescription)"
        }
    }

    private func browseImage() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.title = "Select Reference Image"
        panel.startInLibrary(settings.outputDir)
        if panel.runModal() == .OK, let url = panel.url {
            let ext = url.pathExtension.lowercased()
            if Self.imageExtensions.contains(ext) {
                params.imagePath = settings.adoptSourceImage(url.path)
            }
        }
    }
}
