import SwiftUI

struct ParamsPanelView: View {
    @Bindable var params: ParamsPanelState
    @Environment(AppSettings.self) private var settings

    private var isDistilled: Bool {
        params.model.isDistilled
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Model
                sectionHeader("Model", info: nil)
                ModelPickerView(
                    model: $params.model,
                    customModelRepo: $params.customModelRepo,
                    customBaseModel: $params.customBaseModel,
                    quantize: $params.quantize
                )
                .onChange(of: params.model) { _, m in
                    guard m != .custom else { return }
                    let d = settings.resolvedDefaults(for: m)
                    params.steps          = d.steps
                    params.guidance       = d.guidance
                    params.quantize       = d.quantize
                    params.lowRam         = d.lowRam
                    params.negativePrompt = d.negativePrompt
                    params.width          = d.width
                    params.height         = d.height
                    if !d.loras.isEmpty { params.loras = d.loras }
                }

                Divider()

                // Prompt
                sectionHeader("Prompt", info: "Describe what you want to generate. Be specific about subjects, lighting, style, and mood. More detail generally produces better results.")
                promptEditor
                if !isDistilled {
                    negativePromptEditor
                }

                // Image input — directly below prompt/negative prompt
                img2ImgSection

                // Group / board — directly below image input
                boardRow

                Divider()

                // Dimensions
                DimensionPickerView(width: $params.width, height: $params.height)

                Divider()

                // Steps + Seed (always shown together)
                stepsAndSeedRow

                // Guidance — only for base models
                if !isDistilled {
                    Divider()
                    guidanceRow
                }

                Divider()

                // LoRAs
                LoraManagerView(loras: $params.loras)
                    .padding(.bottom, 8)
            }
            .padding(.leading, 12)
            .padding(.trailing, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Prompt editor (auto-expanding)
    //
    // An invisible Text drives the height: it grows with content (fixedSize vertical),
    // and the TextEditor overlays it exactly. .background() would be constrained to the
    // TextEditor's existing height — useless. The overlay approach is the correct pattern.

    private var promptEditor: some View {
        Text(params.prompt.isEmpty ? " " : params.prompt)
            .font(.body)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 60)
            .opacity(0)
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                TextEditor(text: $params.prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
            }
            .overlay(alignment: .topLeading) {
                if params.prompt.isEmpty {
                    Text("Describe your image…")
                        .foregroundStyle(.tertiary)
                        .font(.body)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .accessibilityLabel("Prompt")
            .accessibilityHint("Describe the image you want to generate")
    }

    private var negativePromptEditor: some View {
        TextEditor(text: $params.negativePrompt)
            .font(.body)
            .frame(minHeight: 44, maxHeight: 100)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if params.negativePrompt.isEmpty {
                    Text("Negative prompt (optional)…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Negative prompt")
            .accessibilityHint("Describe elements to avoid or suppress in the generated image")
    }

    // MARK: - Steps + Seed (one row, always visible)

    private var stepsAndSeedRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Spacer(minLength: 0)
            // Steps
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text("Steps").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                    InfoButton(
                        title: "Denoising Steps",
                        description: "Number of denoising iterations. Distilled models (Klein 4B/9B) work well at 4 steps. Base models need 30–50. More steps = more compute time with diminishing quality returns."
                    )
                }
                Stepper(value: $params.steps, in: 1...150) {
                    TextField("", value: $params.steps, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .onSubmit { params.steps = max(1, min(150, params.steps)) }
                }
                .accessibilityLabel("Steps")
                .accessibilityValue("\(params.steps)")
                .accessibilityHint("Number of denoising iterations")
            }

            Divider().frame(height: 44)

            // Seed
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text("Seed").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                    InfoButton(
                        title: "Random Seed",
                        description: "Controls the randomness of generation. The same seed + prompt produces the same image every time — great for iteration. Use -1 for a unique result each run."
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
                        params.seed = Int.random(in: 0..<1_000_000_000)
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

    // MARK: - Guidance (base models only)

    private var guidanceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text("Guidance").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                InfoButton(
                    title: "Guidance Scale",
                    description: "How closely the model follows your prompt. Higher = stricter adherence but can over-saturate. 3–7 is typical for base models. Distilled Klein models always use 1.0."
                )
            }
            HStack(spacing: 6) {
                Slider(value: $params.guidance, in: 1.0...15.0, step: 0.5)
                    .accessibilityLabel("Guidance")
                    .accessibilityValue(String(format: "%.1f", params.guidance))
                    .accessibilityHint("Higher = follows prompt more strictly")
                Text(String(format: "%.1f", params.guidance))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 28)
            }
        }
    }

    // MARK: - Img2img

    private var img2ImgSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                sectionHeader("Image Input", info: "Optional reference image for image-to-image generation. Drag an image here or click to browse. Higher strength = more influence from your prompt. Lower strength = closer to the original image.")
                Spacer()
                if !params.imagePath.isEmpty {
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
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    providers.first?.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                        guard let data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        let ext = url.pathExtension.lowercased()
                        guard ["png","jpg","jpeg","webp"].contains(ext) else { return }
                        DispatchQueue.main.async { self.params.imagePath = url.path }
                    }
                    return true
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
                            Slider(value: $params.imageStrength, in: 0.1...1.0)
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
    }

    // MARK: - Board row

    private var boardRow: some View {
        HStack(spacing: 6) {
            Text("Group")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            InfoButton(
                title: "Group",
                description: "Organizes generated images into named subfolders inside your output directory. Leave as Default to keep everything in one place."
            )
            TextField("Default", text: $params.board)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .accessibilityLabel("Output group")
                .accessibilityHint("Subfolder name for organizing generated images")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String, info: String?) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            if let info {
                InfoButton(title: title, description: info)
            }
        }
    }

    // MARK: - Helpers

    private func browseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.title = "Select Reference Image"
        if panel.runModal() == .OK, let url = panel.url {
            let ext = url.pathExtension.lowercased()
            if ["png","jpg","jpeg","webp"].contains(ext) {
                params.imagePath = url.path
            }
        }
    }
}

