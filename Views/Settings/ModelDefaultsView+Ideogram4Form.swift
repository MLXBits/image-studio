import SwiftUI

// MARK: - Ideogram 4 default form
//
// Ideogram 4 is a preset-based model whose options (presets, BF16/Q8/Q4 quantize,
// CFG truncation, strict caption validation) diverge from the generic FLUX
// form, so it lives in its own form built from the shared rows in
// `ModelDefaultsView+Rows`. New special models should follow this template:
// one `ModelDefaultsView+<Model>Form.swift` file per model.

extension ModelDefaultsView {
    func ideogram4FormContent() -> some View {
        Form {
            ideogramGenerationSection()
            ideogramCanvasSection()
            ideogramResetSection()
        }
        .formStyle(.grouped)
        .id(FluxModelVariant.ideogram4)
    }

    @ViewBuilder
    private func ideogramGenerationSection() -> some View {
        // Repo + CFG keep explicit bindings: their `nil` carries meaning
        // ("use mflux default" / "full CFG"), so it can't go through the
        // default-substituting `settingsBinding` helper.
        let repoBinding = Binding<String>(
            get: { settings.ideogram4ModelRepoOverride ?? "" },
            set: { settings.ideogram4ModelRepoOverride = $0.isEmpty ? nil : $0 }
        )
        let cfgEndBinding = Binding<Double>(
            get: { settings.ideogram4CfgEnd ?? 1.0 },
            set: { settings.ideogram4CfgEnd = $0 >= 1.0 ? nil : $0 }
        )
        Section("Generation") {
            LabeledContent("Default Preset") {
                Picker("", selection: settingsBinding(\.ideogram4Preset)) {
                    ForEach(Ideogram4Preset.allCases, id: \.self) { preset in
                        Text(preset.labelWithSteps).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
            }

            LabeledContent("Quantization") {
                Picker("", selection: ideogramDefault(\.quantize, default: 8)) {
                    Text("BF16").tag(0)
                    Text("Q8").tag(8)
                    Text("Q4").tag(4)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 80)
            }

            ModelSourceField(
                repo: repoBinding,
                placeholder: "mflux-community/ideogram-4-mflux-bf16",
                infoTitle: "Model source override",
                infoDescription: "HF repo ID or absolute local path to Ideogram 4 weights."
                    + " Leave empty to use the mflux-community repo for the precision."
            ) { browseModelDir(binding: repoBinding) }

            InfoToggleRow(
                title: "Low RAM mode",
                isOn: settingsBinding(\.ideogram4LowRam),
                infoTitle: "Low RAM mode",
                infoDescription: "Streams transformer blocks from disk during generation to reduce"
                    + " peak memory, at a small speed cost. Enable on machines with limited RAM."
            )

            InfoToggleRow(
                title: "Strict caption validation",
                isOn: settingsBinding(\.ideogram4StrictValidation),
                infoTitle: "Strict caption validation",
                infoDescription: "Passes --strict-caption-validation to mflux, rejecting captions"
                    + " that don't match the Ideogram schema instead of silently coercing them."
                    + " Useful when hand-editing or pasting caption JSON."
            )

            InfoSliderRow(
                title: "CFG truncation",
                value: cfgEndBinding,
                range: 0.3 ... 1.0,
                step: 0.05,
                format: { $0 >= 1.0 ? "Off" : "\(Int($0 * 100))%" },
                infoTitle: "CFG truncation (cfg_end)",
                infoDescription: "Runs classifier-free guidance only for this leading fraction of"
                    + " steps, then switches to faster cond-only generation for the rest."
                    + " Guidance mostly shapes the early steps, so e.g. 60% is typically"
                    + " indistinguishable from full while skipping ~40% of the unconditional"
                    + " forward passes. Off = full CFG on every step."
            )
        }
    }

    private func ideogramCanvasSection() -> some View {
        Section {
            DimensionSliderRow(label: "Width", value: ideogramDefault(\.width, default: 1024))
            DimensionSliderRow(label: "Height", value: ideogramDefault(\.height, default: 1024))
        } header: {
            Text("Canvas")
        } footer: {
            Text("Default image size for new Ideogram 4 jobs.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func ideogramResetSection() -> some View {
        Section {
            Button("Reset to Defaults", role: .destructive) {
                resetIdeogramDefaults()
            }
            .foregroundStyle(.red)
            .accessibilityLabel("Reset Ideogram 4 to built-in defaults")
        }
    }

    /// A binding to one of Ideogram's Settings → Models defaults, `defaultValue` when unset.
    private func ideogramDefault(_ field: WritableKeyPath<ModelDefaults, Int?>, default defaultValue: Int) -> Binding<Int> {
        Binding(
            get: { settings.defaults(for: .ideogram4)[keyPath: field] ?? defaultValue },
            set: { value in
                var defaults = settings.defaults(for: .ideogram4)
                defaults[keyPath: field] = value
                settings.updateDefaults(defaults, for: .ideogram4)
            }
        )
    }

    private func resetIdeogramDefaults() {
        settings.ideogram4Preset = .normal
        var defaults = settings.defaults(for: .ideogram4)
        defaults.quantize = nil
        defaults.width = nil
        defaults.height = nil
        settings.updateDefaults(defaults, for: .ideogram4)
        settings.ideogram4ModelRepoOverride = nil
        settings.ideogram4LowRam = false
        settings.ideogram4StrictValidation = false
        settings.ideogram4CfgEnd = nil
    }
}
