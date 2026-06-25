import SwiftUI

/// Krea 2 Turbo submission form. Turbo text-to-image only: prompt (+ optional
/// negative prompt when CFG is on), dimensions, steps, guidance, seed/batch, LoRA,
/// and output folder. Sampler is fixed (er_sde) and there is no edit / img2img path.
struct Krea2ParamsPanelView: View {
    @Bindable var params: Krea2ParamsPanelState
    @Environment(AppSettings.self) private var settings
    @Environment(GalleryStore.self) private var gallery

    private var cfgOn: Bool {
        params.guidance != 1.0
    }

    var body: some View {
        SectionContainerView(
            title: "Prompt",
            info: "Describe what you want to generate. Krea 2 Turbo runs at CFG 1.0 by default; "
                + "raise Guidance above 1 to enable the negative prompt and stricter adherence."
        ) {
            GrowingPromptField(
                text: $params.prompt,
                placeholder: "Describe your image…",
                label: "Prompt",
                hint: "Describe the image you want to generate"
            )
            if cfgOn {
                GrowingPromptField(
                    text: $params.negativePrompt,
                    placeholder: "Negative prompt (optional)…",
                    label: "Negative prompt",
                    hint: "Describe elements to avoid (only used when Guidance > 1)"
                )
            }
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
            DimensionPickerView(width: $params.width, height: $params.height, constraints: .legacy)
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
            modelFamily: .krea2
        ) {
            params.loras = settings.defaultLoras.filter { $0.modelFamily == .krea2 }
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
}
