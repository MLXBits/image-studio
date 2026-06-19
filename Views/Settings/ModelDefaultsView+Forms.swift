import SwiftUI

// MARK: - Per-model form bodies

extension ModelDefaultsView {
    func ideogram4FormContent() -> some View {
        let presetBinding = Binding<Ideogram4Preset>(
            get: { settings.lastIdeogramPreset ?? .normal },
            set: { settings.lastIdeogramPreset = $0 }
        )
        let quantizeBinding = Binding<Int>(
            get: { settings.lastIdeogramQuantize ?? 8 },
            set: { settings.lastIdeogramQuantize = $0 }
        )
        let widthBinding = Binding<Int>(
            get: { settings.lastIdeogramWidth ?? 1024 },
            set: { settings.lastIdeogramWidth = $0 }
        )
        let heightBinding = Binding<Int>(
            get: { settings.lastIdeogramHeight ?? 1024 },
            set: { settings.lastIdeogramHeight = $0 }
        )
        let repoBinding = Binding<String>(
            get: { settings.ideogram4ModelRepoOverride ?? "" },
            set: { settings.ideogram4ModelRepoOverride = $0.isEmpty ? nil : $0 }
        )
        let lowRamBinding = Binding<Bool>(
            get: { settings.ideogram4LowRam },
            set: { settings.ideogram4LowRam = $0 }
        )
        let strictValidationBinding = Binding<Bool>(
            get: { settings.ideogram4StrictValidation },
            set: { settings.ideogram4StrictValidation = $0 }
        )
        let cfgEndBinding = Binding<Double>(
            get: { settings.ideogram4CfgEnd ?? 1.0 },
            set: { settings.ideogram4CfgEnd = $0 >= 1.0 ? nil : $0 }
        )
        return Form {
            Section("Generation") {
                LabeledContent("Default Preset") {
                    Picker("", selection: presetBinding) {
                        ForEach(Ideogram4Preset.allCases, id: \.self) { preset in
                            Text(preset.labelWithSteps).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 160)
                }
                LabeledContent("Quantization") {
                    Picker("", selection: quantizeBinding) {
                        Text("FP8").tag(0)
                        Text("Q8").tag(8)
                        Text("Q4").tag(4)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 80)
                }
                LabeledContent("Model source") {
                    HStack(spacing: 6) {
                        TextField("ideogram-ai/ideogram-4-fp8", text: repoBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit {
                                repoBinding.wrappedValue = repoBinding.wrappedValue
                                    .trimmingCharacters(in: .whitespaces)
                            }
                        Button("Browse…") { browseModelDir(binding: repoBinding) }
                            .controlSize(.small)
                        InfoButton(
                            title: "Model source override",
                            description: "HF repo ID or absolute local path to the Ideogram 4 FP8 weights."
                                + " Leave empty to use the mflux default."
                        )
                    }
                }
                LabeledContent("Low RAM mode") {
                    HStack(spacing: 6) {
                        Toggle("", isOn: lowRamBinding).labelsHidden()
                        InfoButton(
                            title: "Low RAM mode",
                            description: "Streams transformer blocks from disk during generation to reduce"
                                + " peak memory, at a small speed cost. Enable on machines with limited RAM."
                        )
                    }
                }
                LabeledContent("Strict caption validation") {
                    HStack(spacing: 6) {
                        Toggle("", isOn: strictValidationBinding).labelsHidden()
                        InfoButton(
                            title: "Strict caption validation",
                            description: "Passes --strict-caption-validation to mflux, rejecting captions"
                                + " that don't match the Ideogram schema instead of silently coercing them."
                                + " Useful when hand-editing or pasting caption JSON."
                        )
                    }
                }
                LabeledContent("CFG truncation") {
                    HStack(spacing: 6) {
                        Slider(value: cfgEndBinding, in: 0.3 ... 1.0, step: 0.05)
                            .frame(width: 120)
                        Text(settings.ideogram4CfgEnd == nil
                            ? "Off"
                            : "\(Int((settings.ideogram4CfgEnd ?? 1.0) * 100))%")
                            .font(.caption).monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                        InfoButton(
                            title: "CFG truncation (cfg_end)",
                            description: "Runs classifier-free guidance only for this leading fraction of"
                                + " steps, then switches to faster cond-only generation for the rest."
                                + " Guidance mostly shapes the early steps, so e.g. 60% is typically"
                                + " indistinguishable from full while skipping ~40% of the unconditional"
                                + " forward passes. Off = full CFG on every step."
                        )
                    }
                }
            }

            Section {
                HStack {
                    DimensionSliderRow(label: "Width", value: widthBinding)
                }
                HStack {
                    DimensionSliderRow(label: "Height", value: heightBinding)
                }
            } header: {
                Text("Canvas")
            } footer: {
                Text("Default image size for new Ideogram 4 jobs.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings.lastIdeogramPreset = nil
                    settings.lastIdeogramQuantize = nil
                    settings.lastIdeogramWidth = nil
                    settings.lastIdeogramHeight = nil
                    settings.ideogram4ModelRepoOverride = nil
                    settings.ideogram4LowRam = false
                    settings.ideogram4StrictValidation = false
                    settings.ideogram4CfgEnd = nil
                }
                .foregroundStyle(.red)
                .accessibilityLabel("Reset Ideogram 4 to built-in defaults")
            }
        }
        .formStyle(.grouped)
        .id(FluxModelVariant.ideogram4)
    }

    func formContent(model: FluxModelVariant, defaults d: ModelDefaults) -> some View {
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

            if model.supportsNegativePrompt {
                Section {
                    negativePromptField(model: model, current: d.negativePrompt)
                } header: {
                    Text("Negative Prompt")
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

            Section {
                loraOverrideSection(model: model, current: d.loras)
            } header: {
                Text("LoRAs")
            } footer: {
                Text(
                    "Adjusts which LoRAs from the LoRAs tab are enabled and at what"
                        + " strength for this model. Add or remove LoRAs in Settings → LoRAs."
                )
                .font(.caption).foregroundStyle(.tertiary)
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
        .id(model) // force re-render when model changes
    }
}
