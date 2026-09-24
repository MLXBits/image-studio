import AppKit
import SwiftUI

/// Qwen-Image 2.1 submission form. Text-to-image (+ optional img2img init image):
/// prompt, dimensions, steps, seed/batch, guidance, and output folder. The model is
/// sampled guidance-free by default; raising guidance above 1 with a negative
/// prompt switches mflux to true classifier-free guidance. mflux has no LoRA
/// support for Qwen-Image 2.1, so there is no LoRA section.
struct QwenImageParamsPanelView: View {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    @Bindable var params: QwenImageParamsPanelState
    /// Forwarded from ContentView: turns scenario-generated prompts into one job each.
    var onQueueScenarioBatch: ([String]) -> Void = { _ in }
    @Environment(AppSettings.self) private var settings
    @Environment(GalleryStore.self) private var gallery
    @Environment(TimingStore.self) private var timing

    @State private var isImageDropTargeted: Bool = false
    @StateObject private var clipboardMonitor =
        ClipboardImageMonitor(imageExtensions: ["png", "jpg", "jpeg", "webp"])

    /// Learned-time estimate for the current Qwen-Image configuration.
    private var estimate: TimingStore.Estimate? {
        timing.estimate(
            model: params.variant.rawValue,
            quantize: params.quantize, lowRam: false,
            steps: params.steps,
            megapixels: Double(params.width * params.height) / 1_000_000
        )
    }

    var body: some View {
        SectionContainerView(
            title: "Prompt",
            info: "Describe what you want to generate. Qwen-Image 2.1 reads long, detailed "
                + "prompts (up to ~2048 tokens) and renders legible text well.\n\n"
                + "The negative prompt only takes effect with guidance above 1, which turns "
                + "on true classifier-free guidance (and doubles the work per step).\n\n"
                + "Wildcards: {red|black|white} makes Generate run one job per option "
                + "(up to 10), in order. Smaller groups cycle; a batch count overrides."
        ) {
            GrowingPromptField(
                text: $params.prompt,
                placeholder: "Describe your image…",
                label: "Prompt",
                hint: "Describe the image you want to generate",
                tokenSoftCap: params.variant.promptTokenSoftCap
            )
            GrowingPromptField(
                text: $params.negativePrompt,
                placeholder: params.usesTrueCFG
                    ? "Negative prompt (optional)…"
                    : "Negative prompt (needs guidance > 1)…",
                label: "Negative prompt",
                hint: "Describe elements to avoid. Only used when guidance is above 1."
            )
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
                DimensionPickerView(width: $params.width, height: $params.height, constraints: .qwenImage)
                GenerationEstimateView(estimate: estimate, width: params.width, height: params.height)
            }
        }

        Divider()

        SectionContainerView(title: nil, info: nil) {
            stepsAndSeedRow
        }

        Divider()

        SectionContainerView(
            title: "Guidance",
            info: "Qwen-Image 2.1 is trained to run guidance-free, so 1.0 is the reference "
                + "setting. Above 1, together with a negative prompt, mflux runs true "
                + "classifier-free guidance: stricter prompt adherence at twice the compute "
                + "per step. Without a negative prompt, values above 1 have no effect."
        ) {
            guidanceRow
        }
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
                        description: "Qwen-Image 2.1's reference setting is 40 steps. Around 20 "
                            + "gives a quick draft; more than 50 adds compute with diminishing returns."
                    )
                }
                Stepper(value: $params.steps, in: 1 ... 100) {
                    TextField("", value: $params.steps, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .onSubmit { params.steps = max(1, min(100, params.steps)) }
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
                    .buttonStyle(.iconButton)
                    .accessibilityLabel("Pick random seed")
                    Button {
                        params.seed = -1
                    } label: {
                        Image(systemName: "arrow.counterclockwise").font(.caption)
                    }
                    .buttonStyle(.iconButton)
                    .accessibilityLabel("Reset to random (-1)")
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Guidance

    private var guidanceRow: some View {
        HStack(spacing: 6) {
            Slider(value: $params.guidance, in: 1.0 ... 10.0, step: 0.5)
                .accessibilityLabel("Guidance")
                .accessibilityValue(String(format: "%.1f", params.guidance))
                .accessibilityHint("1 runs guidance-free. Higher enables true CFG with a negative prompt.")
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
            params.imagePath = path
            params.adoptResolvedPromptForImg2Img(at: path)
        }
        .dropHighlight(isImageDropTargeted)
    }

    // MARK: - Img2img helpers

    private func pasteImage() {
        let pb = NSPasteboard.general
        // Prefer a file URL so we keep the original file on disk.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            params.imagePath = url.path
            return
        }
        // Fall back to raw image data, saved to a temp PNG.
        guard let image = NSImage(pasteboard: pb) else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasted-qwenimage-\(Int(Date().timeIntervalSince1970)).png")
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
