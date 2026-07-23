import SwiftUI

// MARK: - Z-Image per-model form body
//
// Z-Image is text-to-image (+ img2img). It exposes only the controls the
// `mflux-generate-z-image[-turbo]` CLIs backstop: steps, guidance (base only),
// quantize, and canvas. The distilled Turbo variant is guidance-free, so its
// guidance row is omitted. There is no low-RAM streaming or model-source
// override wired into the Z-Image runner, so those rows are intentionally absent.

extension ModelDefaultsView {
    func zimageFormContent(model: FluxModelVariant) -> some View {
        let d = settings.defaults(for: model)
        return Form {
            Section("Generation") {
                stepsPicker(model: model, current: d.steps)
                if !model.isZImageTurbo {
                    guidancePicker(model: model, current: d.guidance)
                }
                quantizePicker(model: model, current: d.quantize)
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
