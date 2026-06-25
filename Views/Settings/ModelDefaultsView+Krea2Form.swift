import SwiftUI

// MARK: - Krea 2 per-model form body
//
// Krea 2 Turbo is text-to-image with CFG. It exposes only the controls the dev
// `mflux-generate-krea2` CLI backstops: steps, guidance, quantize, canvas, and
// LoRAs. There is no low-RAM streaming and no model-source override wired into
// the Krea 2 runner, so those rows are intentionally omitted.

extension ModelDefaultsView {
    func krea2FormContent() -> some View {
        let model = FluxModelVariant.krea2
        let d = settings.defaults(for: model)
        return Form {
            Section("Generation") {
                stepsPicker(model: model, current: d.steps)
                guidancePicker(model: model, current: d.guidance)
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
                loraOverrideSection(model: model, current: d.loras)
            } header: {
                Text("LoRAs")
            } footer: {
                Text(
                    "Adjusts which Krea 2 LoRAs from the LoRAs tab are enabled and at what"
                        + " strength for this model. Add or remove LoRAs in Settings → LoRAs."
                )
                .font(.caption).foregroundStyle(.tertiary)
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings.updateDefaults(ModelDefaults(), for: model)
                }
                .foregroundStyle(.red)
                .accessibilityLabel("Reset Krea 2 Turbo to built-in defaults")
            }
        }
        .formStyle(.grouped)
        .id(model)
    }
}
