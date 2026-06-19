import AppKit
import SwiftUI

// MARK: - Field builders
// All use LabeledContent so the Form's grouped style aligns labels left and controls right.
// Reset (×) sits to the left of the control so the primary control stays at the trailing edge.

extension ModelDefaultsView {
    func stepsPicker(model: FluxModelVariant, current: Int?) -> some View {
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
                Stepper("", value: bound, in: 1 ... 150).labelsHidden()
            }
        }
        .accessibilityLabel("Default steps for \(model.displayName)")
    }

    func guidancePicker(model: FluxModelVariant, current: Double?) -> some View {
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
                Slider(value: bound, in: 1.0 ... 15.0)
                    .frame(minWidth: 80)
                Text(String(format: "%.1f", bound.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .accessibilityLabel("Default guidance for \(model.displayName)")
    }

    func quantizePicker(model: FluxModelVariant, current: Int?) -> some View {
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

    func modelRepoField(model: FluxModelVariant, current: String?) -> some View {
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

    func lowRamToggle(model: FluxModelVariant, current: Bool?) -> some View {
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

    func negativePromptField(model: FluxModelVariant, current: String?) -> some View {
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
                .accessibilityLabel("Default negative prompt for \(model.displayName)")
                .accessibilityHint("Applied automatically when this model is selected")
            if current != nil {
                resetButton { var d = settings.defaults(for: model); d.negativePrompt = nil; settings.updateDefaults(d, for: model) }
            }
        }
    }

    func widthPicker(model: FluxModelVariant, current: Int?) -> some View {
        dimensionRow(
            label: "Width", model: model, current: current,
            get: \.width,
            set: { var d = settings.defaults(for: model); d.width = $0; settings.updateDefaults(d, for: model) },
            reset: { var d = settings.defaults(for: model); d.width = nil; settings.updateDefaults(d, for: model) }
        )
    }

    func heightPicker(model: FluxModelVariant, current: Int?) -> some View {
        dimensionRow(
            label: "Height", model: model, current: current,
            get: \.height,
            set: { var d = settings.defaults(for: model); d.height = $0; settings.updateDefaults(d, for: model) },
            reset: { var d = settings.defaults(for: model); d.height = nil; settings.updateDefaults(d, for: model) }
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func dimensionRow(
        label: String, model: FluxModelVariant, current: Int?,
        get _: KeyPath<ModelDefaults, Int?>,
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

    @ViewBuilder
    func loraOverrideSection(model: FluxModelVariant, current: [LoraEntry]?) -> some View {
        let globals = settings.defaultLoras
        if globals.isEmpty {
            Text("No LoRAs configured. Add them in the LoRAs tab.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            VStack(spacing: 6) {
                ForEach(globals) { global in
                    let eff = current?.first { $0.path == global.path } ?? global
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { eff.enabled },
                                set: { v in setLoraEnabled(v, path: global.path, model: model, globals: globals, current: current) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .scaleEffect(0.7)
                            .frame(width: 32, height: 20)
                            Text(global.displayName)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 6) {
                            Slider(value: Binding(
                                get: { eff.strength },
                                set: { v in setLoraStrength(v, path: global.path, model: model, globals: globals, current: current) }
                            ), in: 0 ... 2)
                            Text(String(format: "%.2f", eff.strength))
                                .font(.caption2)
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    .padding(8)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                }
                if current != nil {
                    HStack {
                        Spacer()
                        Button("Reset to LoRAs tab defaults") {
                            var d = settings.defaults(for: model)
                            d.loras = nil
                            settings.updateDefaults(d, for: model)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func setLoraEnabled(
        _ enabled: Bool, path: String, model: FluxModelVariant,
        globals: [LoraEntry], current: [LoraEntry]?
    ) {
        var list = current ?? globals
        if let idx = list.firstIndex(where: { $0.path == path }) {
            list[idx].enabled = enabled
        } else if let global = globals.first(where: { $0.path == path }) {
            var entry = global; entry.enabled = enabled; list.append(entry)
        }
        var d = settings.defaults(for: model); d.loras = list
        settings.updateDefaults(d, for: model)
    }

    private func setLoraStrength(
        _ strength: Double, path: String, model: FluxModelVariant,
        globals: [LoraEntry], current: [LoraEntry]?
    ) {
        let rounded = round(strength / 0.05) * 0.05
        var list = current ?? globals
        if let idx = list.firstIndex(where: { $0.path == path }) {
            list[idx].strength = rounded
        } else if let global = globals.first(where: { $0.path == path }) {
            var entry = global; entry.strength = rounded; list.append(entry)
        }
        var d = settings.defaults(for: model); d.loras = list
        settings.updateDefaults(d, for: model)
    }

    func browseModelDir(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "Select Model Directory"
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    /// A small × button to clear an override back to the model default
    func resetButton(_ action: @escaping () -> Void) -> some View {
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
