import SwiftUI

// MARK: - Qwen-Image 2.1 per-model form body
//
// Qwen-Image 2.1 Turbo is guidance-free, and each precision is its own published
// repo, so the form has no guidance and no model-source override.

extension ModelDefaultsView {
    func qwen21FormContent(models: ComfyModelStore) -> some View {
        let model = FluxModelVariant.qwen21Turbo
        let d = settings.defaults(for: model)
        let key = ModelFamily.qwen21.id
        return Form {
            comfyBackendPicker(family: .qwen21)

            if settings.comfyBackendEnabled[key] == true {
                Section {
                    comfyServerRow(models: models)

                    comfyFileRow(
                        "UNet model", \.comfyUNet, options: models.unets,
                        placeholder: "qwen_image_2.1_turbo_int8_convrot.safetensors", key: key
                    )
                    comfyFileRow(
                        "CLIP encoder", \.comfyClip, options: models.clips,
                        placeholder: "qwen3vl_8b_int8_convrot.safetensors", key: key
                    )
                    comfyFileRow(
                        "VAE", \.comfyVae, options: models.vaes,
                        placeholder: "qwen_image_2.1_vae_bf16.safetensors", key: key
                    )
                    comfyFileRow(
                        "Prompt enhancer CLIP", \.comfyClip, options: models.clips,
                        placeholder: "qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot.safetensors", key: Qwen21RunnerSpec.enhancerClipKey
                    )
                } footer: {
                    Text(
                        "Runs on the remote box using these files. The enhancer CLIP is only loaded for jobs with " +
                            "Enhance prompt on. Local mflux and this config are saved independently."
                    )
                    .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Section {
                stepsPicker(model: model, current: d.steps)
                quantizePicker(model: model, current: d.quantize)
                lowRamToggle(model: model, current: d.lowRam)
            } footer: {
                Text("BF16, Q8 and Q4 each download their own mflux-community repo the first time they're used.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section {
                widthPicker(model: model, defaults: d)
                heightPicker(model: model, defaults: d)
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
                .accessibilityLabel("Reset Qwen Image 2.1 Turbo to built-in defaults")
            }
        }
        .formStyle(.grouped)
        .id(model)
    }
}
