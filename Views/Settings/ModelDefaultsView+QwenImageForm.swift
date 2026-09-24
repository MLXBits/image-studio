import SwiftUI

// MARK: - Qwen-Image 2.1 per-model form body
//
// Qwen-Image 2.1 is text-to-image (+ img2img). It exposes only the controls the
// `mflux-generate-qwen-2.1` CLI backstops: steps, guidance, quantize, model
// source, and canvas. Q8/Q4 quantize in memory at load (the Qwen3-VL text encoder
// stays BF16). There is no low-RAM streaming, so that row is intentionally absent.

extension ModelDefaultsView {
    func qwenImageFormContent(model: FluxModelVariant) -> some View {
        let d = settings.defaults(for: model)
        return Form {
            Section {
                stepsPicker(model: model, current: d.steps)
                guidancePicker(model: model, current: d.guidance)
                quantizePicker(model: model, current: d.quantize)
                modelRepoField(model: model, current: d.modelRepoOverride)
            } header: {
                Text("Generation")
            } footer: {
                Text("Guidance 1.0 is the model's guidance-free reference. Above 1 it only "
                    + "takes effect together with a negative prompt.")
                    .font(.caption).foregroundStyle(.tertiary)
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
        .id(model)
    }
}
