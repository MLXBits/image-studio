import SwiftUI

struct ParamsPanelView: View {
    @Bindable var params: ParamsPanelState
    @Environment(AppSettings.self) private var settings
    let onGenerate: () -> Void

    @State private var showingAdvanced: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Model")
                ModelPickerView(
                    model: $params.model,
                    customModelRepo: $params.customModelRepo,
                    customBaseModel: $params.customBaseModel,
                    quantize: $params.quantize
                )
                .onChange(of: params.model) { _, m in
                    guard m != .custom else { return }
                    params.steps = m.defaultSteps
                    params.guidance = m.defaultGuidance
                }

                Divider()

                sectionLabel("Prompt")
                TextEditor(text: $params.prompt)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 160)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if params.prompt.isEmpty {
                            Text("Describe your image…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }

                if showingAdvanced || params.model.supportsNegativePrompt {
                    TextEditor(text: $params.negativePrompt)
                        .font(.body)
                        .frame(minHeight: 40, maxHeight: 80)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if params.negativePrompt.isEmpty {
                                Text("Negative prompt…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Divider()

                sectionLabel("Dimensions")
                DimensionPickerView(width: $params.width, height: $params.height)

                Divider()

                generationParams

                Divider()

                LoraManagerView(loras: $params.loras)

                Divider()

                img2ImgSection

                Divider()

                advancedSection

                Divider()

                generateButton
                    .padding(.bottom, 8)
            }
            .padding(12)
        }
    }

    // MARK: - Generation params

    private var generationParams: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Steps").font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Stepper("", value: $params.steps, in: 1...150)
                            .labelsHidden()
                        Text("\(params.steps)")
                            .font(.caption).monospacedDigit()
                            .frame(width: 24)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guidance").font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $params.guidance, in: 1.0...15.0, step: 0.5)
                            .frame(maxWidth: 80)
                        Text(String(format: "%.1f", params.guidance))
                            .font(.caption).monospacedDigit()
                            .frame(width: 28)
                    }
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Seed").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("-1", value: $params.seed, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(width: 80)
                        Button {
                            params.seed = Int.random(in: 0..<1_000_000_000)
                        } label: {
                            Image(systemName: "dice").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Pick random seed")
                        Button {
                            params.seed = -1
                        } label: {
                            Image(systemName: "arrow.counterclockwise").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Reset to random (-1)")
                    }
                }

                Spacer()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Batch").font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Stepper("", value: $params.batchCount, in: 1...16)
                            .labelsHidden()
                        Text("\(params.batchCount)")
                            .font(.caption).monospacedDigit()
                            .frame(width: 20)
                    }
                }
            }
        }
    }

    // MARK: - Img2img

    private var img2ImgSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("Image Input")
                Spacer()
                if !params.imagePath.isEmpty {
                    Button { params.imagePath = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: params.imagePath).lastPathComponent)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 4) {
                            Text("Strength").font(.caption2).foregroundStyle(.secondary)
                            Slider(value: $params.imageStrength, in: 0.1...1.0, step: 0.05)
                            Text(String(format: "%.2f", params.imageStrength))
                                .font(.caption2).monospacedDigit().frame(width: 28)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Low RAM", isOn: $params.lowRam)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Spacer()
                }
                HStack {
                    Text("Board").font(.caption2).foregroundStyle(.secondary)
                    TextField("Default", text: $params.board)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Generate button

    private var generateButton: some View {
        Button { onGenerate() } label: {
            HStack {
                Image(systemName: "wand.and.stars")
                Text(params.batchCount > 1 ? "Generate ×\(params.batchCount)" : "Generate")
                    .fontWeight(.semibold)
                Text("⌘↵")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(params.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
    }

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

private extension NSImage {
    convenience init?(data: Data?) {
        guard let data else { return nil }
        self.init(data: data)
    }
}
