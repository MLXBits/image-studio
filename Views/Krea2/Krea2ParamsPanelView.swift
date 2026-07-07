import AppKit
import SwiftUI

/// Krea 2 Turbo submission form. Turbo text-to-image (+ optional img2img init
/// image): prompt (+ optional negative prompt when CFG is on), dimensions, steps,
/// guidance, seed/batch, LoRA, and output folder. Sampler is fixed (er_sde) and
/// there is no multi-image edit path.
struct Krea2ParamsPanelView: View {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    @Bindable var params: Krea2ParamsPanelState
    @Environment(AppSettings.self) private var settings
    @Environment(GalleryStore.self) private var gallery
    @Environment(TimingStore.self) private var timing
    @Environment(LoraLibraryStore.self) private var loraLibrary

    @State private var isImageDropTargeted: Bool = false

    private var cfgOn: Bool {
        params.guidance != 1.0
    }

    /// Learned-time estimate for the current Krea 2 configuration.
    private var estimate: TimingStore.Estimate? {
        timing.estimate(
            model: "krea2",
            quantize: params.quantize, lowRam: false,
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
                ScenarioGeneratorButton { params.prompt = $0 }
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
                DimensionPickerView(width: $params.width, height: $params.height, constraints: .legacy)
                GenerationEstimateView(estimate: estimate)
            }
        }

        Divider()

        SectionContainerView(title: nil, info: nil) {
            stepsAndSeedRow
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
            defaultLoras: settings.defaultLoras.filter { $0.modelFamily == .krea2 },
            modelFamily: .krea2,
            library: loraLibrary,
            onInsertTriggerWords: { params.prompt = insertTriggerWords($0, into: params.prompt) },
            onReset: {
                params.loras = settings.defaultLoras.filter { $0.modelFamily == .krea2 }
            }
        )
        .padding(.bottom, 8)
    }

    // MARK: - Steps + Seed (one row)

    private var stepsAndSeedRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text("Steps").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                    InfoButton(
                        title: "Denoising Steps",
                        description: "Krea 2 Turbo is distilled for 8 steps. More steps add compute "
                            + "with diminishing returns; fewer may reduce quality."
                    )
                }
                Stepper(value: $params.steps, in: 1 ... 50) {
                    TextField("", value: $params.steps, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .onSubmit { params.steps = max(1, min(50, params.steps)) }
                }
                .accessibilityLabel("Steps")
                .accessibilityValue("\(params.steps)")
            }

            Divider().frame(height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text("Seed").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                    InfoButton(
                        title: "Random Seed",
                        description: "The same seed + prompt produces the same image every time. "
                            + "Use -1 for a unique result each run."
                    )
                }
                HStack(spacing: 4) {
                    TextField("-1", value: $params.seed, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 100)
                        .accessibilityLabel("Seed")
                        .accessibilityHint("Use -1 for random")
                    Button {
                        params.seed = Int.random(in: 0 ..< 1_000_000_000)
                    } label: {
                        Image(systemName: "dice").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pick random seed")
                    Button {
                        params.seed = -1
                    } label: {
                        Image(systemName: "arrow.counterclockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset to random (-1)")
                }
            }
            Spacer(minLength: 0)
        }
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
                    .buttonStyle(.plain)
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

                    if clipboardHasImage {
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
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .dropDestination(for: String.self, action: { paths, _ in
            guard let path = paths.first else { return false }
            let ext = (path as NSString).pathExtension.lowercased()
            guard Self.imageExtensions.contains(ext) else { return false }
            params.imagePath = path
            params.adoptResolvedPromptForImg2Img(at: path)
            return true
        }, isTargeted: { isImageDropTargeted = $0 })
        .onDrop(of: [.fileURL], isTargeted: $isImageDropTargeted) { providers in
            providers.first?.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                guard Self.imageExtensions.contains(ext) else { return }
                DispatchQueue.main.async {
                    self.params.imagePath = url.path
                    self.params.adoptResolvedPromptForImg2Img(at: url.path)
                }
            }
            return true
        }
        .dropHighlight(isImageDropTargeted)
    }

    // MARK: - Img2img helpers

    private var clipboardHasImage: Bool {
        let pb = NSPasteboard.general
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
            || pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
            .compactMap { $0 as? URL }
            .first { Self.imageExtensions.contains($0.pathExtension.lowercased()) } != nil
    }

    private func pasteImage() {
        let pb = NSPasteboard.general
        // Prefer a file URL so we keep the original file on disk.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            params.imagePath = url.path
            return
        }
        // Fall back to raw image data — save to a temp PNG.
        guard let image = NSImage(pasteboard: pb) else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasted-krea2-\(Int(Date().timeIntervalSince1970)).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: tmp)
        params.imagePath = tmp.path
    }

    private func browseImage() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.title = "Select Reference Image"
        if panel.runModal() == .OK, let url = panel.url {
            let ext = url.pathExtension.lowercased()
            if Self.imageExtensions.contains(ext) {
                params.imagePath = url.path
            }
        }
    }
}
