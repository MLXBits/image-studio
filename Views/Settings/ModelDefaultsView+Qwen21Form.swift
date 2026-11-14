import SwiftUI

// MARK: - Qwen-Image 2.1 per-model form body
//
// Qwen-Image 2.1 Turbo is guidance-free, and each precision is its own published
// repo, so the form has no guidance and no model-source override.

extension ModelDefaultsView {
    func qwen21FormContent() -> some View {
        let model = FluxModelVariant.qwen21Turbo
        let d = settings.defaults(for: model)
        return Form {
            Section {
                stepsPicker(model: model, current: d.steps)
                quantizePicker(model: model, current: d.quantize)
                lowRamToggle(model: model, current: d.lowRam)
            } footer: {
                Text("BF16, Q8 and Q4 each download their own mflux-community repo the first time they're used.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section {
                widthPicker(model: model, current: d.width)
                heightPicker(model: model, current: d.height)
            } header: {
                Text("Canvas")
            } footer: {
                Text("Generate mode's size. Edit mode sizes from the last reference unless you turn that off in the panel.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings.updateDefaults(ModelDefaults(), for: model)
                }
                .foregroundStyle(.red)
                .accessibilityLabel("Reset Qwen-Image 2.1 Turbo to built-in defaults")
            }
        }
        .formStyle(.grouped)
        .id(model)
    }
}
