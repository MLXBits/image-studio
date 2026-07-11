import SwiftUI

// MARK: - Generic per-model form body
//
// Shared form covering every FLUX variant via the field builders in
// `ModelDefaultsView+Fields`. Models whose options diverge (e.g. Ideogram 4)
// get their own `ModelDefaultsView+<Model>Form.swift`.

extension ModelDefaultsView {
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
