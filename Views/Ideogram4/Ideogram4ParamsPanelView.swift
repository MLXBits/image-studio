import SwiftUI

/// Ideogram 4 param fields — no ScrollView wrapper; embedded inside ParamsPanelView's scroll.
/// Quantize lives in the shared Model section above this view.
struct Ideogram4ParamsPanelView: View {
    @Bindable var params: Ideogram4ParamsPanelState
    @Environment(AppSettings.self) private var settings
    @Environment(GalleryStore.self) private var gallery

    @State private var seedText: String = ""
    @State private var batchSeedText: String = ""
    @State private var showBatchSeeds: Bool = false
    @State private var captionExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Caption / prompt — collapsible (open by default)
            captionSection

            Divider()

            // Preset
            SectionContainerView(
                title: "Preset",
                info: "Quality preset for generation. Higher quality = more steps = slower."
            ) {
                presetPicker
            }

            Divider()

            // Dimensions
            SectionContainerView(title: "Dimensions", info: "Output image size. Range: 256–2048, multiples of 16.") {
                DimensionPickerView(width: $params.width, height: $params.height)
                    .onChange(of: params.width) { _, w in
                        params.width = Ideogram4Preset.clampDimension(w)
                    }
                    .onChange(of: params.height) { _, h in
                        params.height = Ideogram4Preset.clampDimension(h)
                    }
            }

            Divider()

            // Seed
            SectionContainerView(title: "Seed") {
                seedSection
            }

            Divider()

            // LoRAs
            LoraManagerView(
                loras: $params.loras,
                defaultLoras: settings.defaultLoras.filter { $0.modelFamily == .ideogram4 },
                modelFamily: .ideogram4
            ) {
                params.loras = settings.defaultLoras.filter { $0.modelFamily == .ideogram4 }
            }

            Divider()

            // Options (low RAM, strict validation, HF token warning)
            SectionContainerView(title: "Options") {
                optionsSection
            }

            Divider()

            // Board
            SectionContainerView(title: "Board") {
                FolderComboBox(text: $params.board, options: gallery.boards, placeholder: "Default")
            }

            Spacer(minLength: 16)
        }
    }

    // MARK: - Subviews (instance_property)

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { captionExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: captionExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Text("Caption")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if captionExpanded {
                IdeogramCaptionEditorView(
                    caption: $params.caption,
                    usePlainPrompt: $params.usePlainPrompt,
                    plainPrompt: $params.plainPrompt,
                    outputWidth: params.width,
                    outputHeight: params.height
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $params.preset) {
                ForEach(Ideogram4Preset.allCases, id: \.self) { preset in
                    Text(preset.labelWithSteps).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(presetDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var presetDescription: String {
        switch params.preset {
        case .turbo: "Fast iteration — good for exploring compositions and prompts."
        case .normal: "Balanced quality and speed. Recommended for most generations."
        case .quality: "Highest quality. Best for final renders and detailed scenes."
        }
    }

    private var seedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Random", text: $seedText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .onChange(of: seedText) { _, text in
                        params.seed = Int(text) ?? -1
                    }
                    .onAppear { seedText = params.seed >= 0 ? "\(params.seed)" : "" }

                Button {
                    seedText = ""
                    params.seed = -1
                    params.batchSeeds = []
                    showBatchSeeds = false
                } label: {
                    Image(systemName: "dice")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Random seed")

                Spacer()

                Toggle("Batch", isOn: $showBatchSeeds)
                    .toggleStyle(.button)
                    .controlSize(.small)
            }

            if showBatchSeeds {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Additional seeds (space-separated)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("e.g. 42 137 8001", text: $batchSeedText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: batchSeedText) { _, text in
                            params.batchSeeds = text
                                .components(separatedBy: .whitespaces)
                                .compactMap { Int($0) }
                        }
                }
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Low RAM", isOn: $params.lowRam)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Toggle("Strict validation", isOn: $params.strictValidation)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Pass --strict-caption-validation to reject captions that don't match the schema")
            }

            if settings.hfToken.isEmpty &&
                !settings.ideogram4ModelOnDisk(quantize: params.quantize) {
                hfTokenWarning
            }
        }
    }

    private var hfTokenWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hugging Face token required")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(
                    "Ideogram 4 is a gated model (~28 GB). Request access on the model card, "
                        + "then set your HF token in Settings → Advanced."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.yellow.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
