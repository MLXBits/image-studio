import SwiftUI

// MARK: - FLUX.2 per-model form body
//
// The four FLUX.2 Klein variants share one `.flux` family and one ComfyUI
// backend toggle (`comfyBackendEnabled[ModelFamily.flux.id]` — the same key
// `JobRunner.makeComfyTarget` gates on), but each variant routes its own
// UNet/CLIP/VAE filenames (`comfyUNet/Clip/Vae[variant.rawValue]`, read by
// `FluxRunnerSpec.comfyGraph`). FLUX.3 is a separate workstream and keeps the
// generic form.

/// The t2i template's baked-in filenames for each FLUX.2 variant — placeholder hints for the
/// file rows (the user's server files may differ; the picker falls back to free text when
/// nothing is discovered).
private struct Flux2TemplateFiles {
    static func forVariant(_ variant: FluxModelVariant) -> Self {
        switch variant {
        case .flux2Klein4B:
            Self(unet: "flux-2-klein-4b.safetensors", clip: "qwen_3_4b.safetensors", vae: "flux2-vae.safetensors")
        case .flux2Klein9B:
            Self(
                unet: "flux-2-klein-9b-fp8.safetensors",
                clip: "qwen_3_8b_fp8mixed.safetensors",
                vae: "full_encoder_small_decoder.safetensors"
            )
        case .flux2KleinBase4B:
            Self(unet: "flux-2-klein-base-4b.safetensors", clip: "qwen_3_4b.safetensors", vae: "flux2-vae.safetensors")
        case .flux2KleinBase9B:
            Self(
                unet: "flux-2-klein-base-9b-fp8.safetensors",
                clip: "qwen_3_8b_fp8mixed.safetensors",
                vae: "full_encoder_small_decoder.safetensors"
            )
        default:
            Self(unet: "", clip: "", vae: "")
        }
    }

    let unet: String
    let clip: String
    let vae: String
}

extension ModelDefaultsView {
    func flux2FormContent(model: FluxModelVariant, defaults d: ModelDefaults, models: ComfyModelStore) -> some View {
        let remote = settings.comfyBackendEnabled[ModelFamily.flux.id] == true
        return Form {
            comfyBackendPicker(family: .flux)

            if remote {
                Section {
                    comfyServerRow(models: models)
                } footer: {
                    Text(
                        "Runs on the remote box using these files. Local mflux and this config are saved independently, " +
                            "so switching back never loses either."
                    )
                    .font(.caption).foregroundStyle(.tertiary)
                }
                Section {
                    let files = Flux2TemplateFiles.forVariant(model)
                    comfyFileRow("UNet model", \.comfyUNet, options: models.unets, placeholder: files.unet, key: model.rawValue)
                    comfyFileRow("CLIP encoder", \.comfyClip, options: models.clips, placeholder: files.clip, key: model.rawValue)
                    comfyFileRow("VAE", \.comfyVae, options: models.vaes, placeholder: files.vae, key: model.rawValue)
                } header: {
                    Text(model.displayName)
                } footer: {
                    if !flux2FilesComplete(model) {
                        Label(
                            "Remote routing stays off until all three files are set for this variant.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                if !remote {
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
                } else {
                    Text(
                        "Steps, guidance, and LoRAs are sent to the server per job from the FLUX params panel — " +
                            "they don't apply on the mflux side here."
                    )
                    .font(.caption).foregroundStyle(.secondary)
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

    /// True when all three remote model files (UNet/CLIP/VAE) are stored for this variant —
    /// the same three `FluxRunnerSpec.comfyGraph` gates on before routing a job to ComfyUI.
    private func flux2FilesComplete(_ model: FluxModelVariant) -> Bool {
        !((settings.comfyUNet[model.rawValue] ?? "").isEmpty
            || (settings.comfyClip[model.rawValue] ?? "").isEmpty
            || (settings.comfyVae[model.rawValue] ?? "").isEmpty)
    }
}
