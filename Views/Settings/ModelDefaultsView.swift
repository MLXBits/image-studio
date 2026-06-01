import SwiftUI

/// Per-model settings form. Shows inside the Settings "Models" tab.
struct ModelDefaultsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedModel: FluxModelVariant = FluxModelVariant.builtIn[0]

    var body: some View {
        HStack(spacing: 0) {
            // Left: model list
            modelList
                .frame(width: 160)
            Divider()
            // Right: settings for selected model
            modelForm
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Model list

    private var modelList: some View {
        List(FluxModelVariant.builtIn, id: \.self, selection: $selectedModel) { model in
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.callout)
                Text(model.isDistilled ? "Distilled · \(model.defaultSteps) steps" : "Base · \(model.defaultSteps) steps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .tag(model)
        }
        .listStyle(.sidebar)
    }

    // MARK: - Per-model form

    private var modelForm: some View {
        let d = settings.defaults(for: selectedModel)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                modelHeader
                Divider()
                formContent(model: selectedModel, defaults: d)
            }
        }
    }

    private var modelHeader: some View {
        let d = settings.defaults(for: selectedModel)
        let quantize = d.quantize ?? selectedModel.recommendedQuantize
        let factor: Double = quantize == 4 ? 0.25 : quantize == 8 ? 0.5 : 1.0
        let vramGB = selectedModel.approximateBF16SizeGB * factor
        let quantLabel = quantize == 0 ? "BF16" : "Q\(quantize)"
        let vramColor: Color = vramGB > 30 ? .orange : vramGB > 18 ? .yellow : .green

        return VStack(alignment: .leading, spacing: 6) {
            Text(selectedModel.displayName)
                .font(.headline)

            HStack(spacing: 10) {
                Label(
                    selectedModel.isDistilled ? "Distilled" : "Base model",
                    systemImage: selectedModel.isDistilled ? "bolt.fill" : "cpu"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if vramGB > 0 {
                    Label(
                        "≈\(String(format: "%.0f", vramGB)) GB with \(quantLabel)",
                        systemImage: "memorychip"
                    )
                    .font(.caption)
                    .foregroundStyle(vramColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(vramColor.opacity(0.1), in: Capsule())
                }
            }

            Text("Overrides global defaults when this model is selected. The memory estimate above reflects your current quantize setting.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    @ViewBuilder
    private func formContent(model: FluxModelVariant, defaults d: ModelDefaults) -> some View {
        Form {
            Section("Generation") {
                stepsPicker(model: model, current: d.steps)
                if !model.isDistilled {
                    guidancePicker(model: model, current: d.guidance)
                } else {
                    LabeledContent("Guidance") {
                        Text("Fixed at 1.0 (distilled)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                quantizePicker(model: model, current: d.quantize)
                modelRepoField(model: model, current: d.modelRepoOverride)
                lowRamToggle(model: model, current: d.lowRam)
            }

            Section {
                negativePromptField(model: model, current: d.negativePrompt)
            } header: {
                Text("Negative Prompt")
            } footer: {
                if model.isDistilled {
                    Text("Negative prompts are not supported by distilled Klein 4B/9B models.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Section {
                widthPicker(model: model, current: d.width)
                heightPicker(model: model, current: d.height)
            } header: {
                Text("Canvas")
            } footer: {
                Text("Falls back to the global default size in Generation if not overridden here.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section("Default LoRAs") {
                loraSection(model: model, current: d.loras)
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings.updateDefaults(ModelDefaults(), for: model)
                }
                .foregroundStyle(.red)
                .accessibilityLabel("Reset \(model.displayName) to built-in defaults")
            }
        }
        .formStyle(.grouped)
        .id(model)  // force re-render when model changes
    }

    // MARK: - Field builders
    // All use LabeledContent so the Form's grouped style aligns labels left and controls right.
    // Reset (×) sits to the left of the control so the primary control stays at the trailing edge.

    private func stepsPicker(model: FluxModelVariant, current: Int?) -> some View {
        let bound = Binding<Int>(
            get: { current ?? model.defaultSteps },
            set: { newVal in
                var d = settings.defaults(for: model); d.steps = newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LabeledContent("Steps") {
            HStack(spacing: 6) {
                if current != nil {
                    resetButton { var d = settings.defaults(for: model); d.steps = nil; settings.updateDefaults(d, for: model) }
                }
                TextField("", value: bound, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .onSubmit { bound.wrappedValue = max(1, min(150, bound.wrappedValue)) }
                Stepper("", value: bound, in: 1...150).labelsHidden()
            }
        }
        .accessibilityLabel("Default steps for \(model.displayName)")
    }

    private func guidancePicker(model: FluxModelVariant, current: Double?) -> some View {
        let bound = Binding<Double>(
            get: { current ?? model.defaultGuidance },
            set: { newVal in
                var d = settings.defaults(for: model); d.guidance = newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LabeledContent("Guidance") {
            HStack(spacing: 6) {
                if current != nil {
                    resetButton { var d = settings.defaults(for: model); d.guidance = nil; settings.updateDefaults(d, for: model) }
                }
                Slider(value: bound, in: 1.0...15.0)
                    .frame(minWidth: 80)
                Text(String(format: "%.1f", bound.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .accessibilityLabel("Default guidance for \(model.displayName)")
    }

    private func quantizePicker(model: FluxModelVariant, current: Int?) -> some View {
        let bound = Binding<Int>(
            get: { current ?? model.recommendedQuantize },
            set: { newVal in
                var d = settings.defaults(for: model); d.quantize = newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LabeledContent("Quantization") {
            HStack(spacing: 6) {
                if current != nil {
                    resetButton { var d = settings.defaults(for: model); d.quantize = nil; settings.updateDefaults(d, for: model) }
                }
                Picker("", selection: bound) {
                    Text("BF16").tag(0)
                    Text("Q8").tag(8)
                    Text("Q4").tag(4)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 80)
            }
        }
        .accessibilityLabel("Default quantization for \(model.displayName)")
    }

    private func modelRepoField(model: FluxModelVariant, current: String?) -> some View {
        let bound = Binding<String>(
            get: { current ?? "" },
            set: { newVal in
                var d = settings.defaults(for: model)
                d.modelRepoOverride = newVal.isEmpty ? nil : newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LabeledContent("Model source") {
            HStack(spacing: 6) {
                if current != nil {
                    resetButton {
                        var d = settings.defaults(for: model)
                        d.modelRepoOverride = nil
                        settings.updateDefaults(d, for: model)
                    }
                }
                TextField("org/repo or /path/to/weights", text: bound)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .font(.caption)
                    .onSubmit {
                        let trimmed = bound.wrappedValue.trimmingCharacters(in: .whitespaces)
                        bound.wrappedValue = trimmed
                    }
                Button("Browse…") { browseModelDir(binding: bound) }
                    .controlSize(.small)
                InfoButton(
                    title: "Model source override",
                    description: "HF repo ID (e.g. mlx-community/flux2-klein-9b-8bit) " +
                        "or absolute local path. When set, replaces the mflux default for this model. " +
                        "The --quantize flag is not passed — the repo's own weight metadata is used."
                )
            }
        }
        .accessibilityLabel("Model source override for \(model.displayName)")
    }

    private func lowRamToggle(model: FluxModelVariant, current: Bool?) -> some View {
        let bound = Binding<Bool>(
            get: { current ?? false },
            set: { newVal in
                var d = settings.defaults(for: model); d.lowRam = newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LabeledContent("Low RAM mode") {
            HStack(spacing: 6) {
                if current != nil {
                    resetButton { var d = settings.defaults(for: model); d.lowRam = nil; settings.updateDefaults(d, for: model) }
                }
                Toggle("", isOn: bound).labelsHidden()
            }
        }
        .accessibilityLabel("Default low RAM mode for \(model.displayName)")
        .accessibilityHint("Streams transformer blocks from disk to reduce peak memory")
    }

    private func negativePromptField(model: FluxModelVariant, current: String?) -> some View {
        let bound = Binding<String>(
            get: { current ?? "" },
            set: { newVal in
                var d = settings.defaults(for: model)
                d.negativePrompt = newVal.isEmpty ? nil : newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return HStack(alignment: .top) {
            TextEditor(text: bound)
                .font(.caption)
                .frame(minHeight: 60)
                .disabled(model.isDistilled)
                .accessibilityLabel("Default negative prompt for \(model.displayName)")
                .accessibilityHint("Applied automatically when this model is selected")
            if current != nil && !model.isDistilled {
                resetButton { var d = settings.defaults(for: model); d.negativePrompt = nil; settings.updateDefaults(d, for: model) }
            }
        }
    }

    private func widthPicker(model: FluxModelVariant, current: Int?) -> some View {
        dimensionRow(
            label: "Width", model: model, current: current,
            get: \.width,
            set: { var d = settings.defaults(for: model); d.width = $0; settings.updateDefaults(d, for: model) },
            reset: { var d = settings.defaults(for: model); d.width = nil; settings.updateDefaults(d, for: model) }
        )
    }

    private func heightPicker(model: FluxModelVariant, current: Int?) -> some View {
        dimensionRow(
            label: "Height", model: model, current: current,
            get: \.height,
            set: { var d = settings.defaults(for: model); d.height = $0; settings.updateDefaults(d, for: model) },
            reset: { var d = settings.defaults(for: model); d.height = nil; settings.updateDefaults(d, for: model) }
        )
    }

    private func dimensionRow(
        label: String, model: FluxModelVariant, current: Int?,
        get: KeyPath<ModelDefaults, Int?>,
        set: @escaping (Int) -> Void,
        reset: @escaping () -> Void
    ) -> some View {
        let bound = Binding<Int>(
            get: { current ?? 1024 },
            set: { set($0) }
        )
        return HStack {
            DimensionSliderRow(label: label, value: bound)
            if current != nil {
                resetButton(reset)
            }
        }
        .accessibilityLabel("Default \(label.lowercased()) for \(model.displayName)")
    }

    private func loraSection(model: FluxModelVariant, current: [LoraEntry]?) -> some View {
        let bound = Binding<[LoraEntry]>(
            get: { current ?? [] },
            set: { newVal in
                var d = settings.defaults(for: model)
                d.loras = newVal.isEmpty ? nil : newVal
                settings.updateDefaults(d, for: model)
            }
        )
        return LoraManagerView(loras: bound)
    }

    private func browseModelDir(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "Select Model Directory"
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    // A small × button to clear an override back to the model default
    private func resetButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Reset to built-in default")
        .accessibilityLabel("Reset to built-in default")
    }
}
