import SwiftUI

// MARK: - SeedVR2 defaults form body
//
// SeedVR2 is an upscale *action*, not a picker-selectable generative model, so it
// has no per-model ModelDefaults record. These controls bind directly to the
// AppSettings scalar fields that seed the Upscale sheet (`seedVR2*`).

extension ModelDefaultsView {
    private var seedVR2Header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SeedVR2").font(.headline)
            Label("Diffusion upscaler", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.caption).foregroundStyle(.secondary)
            Text(
                "Prompt-free super-resolution applied to gallery images via the "
                    + "Upscale action. These are the defaults the Upscale sheet opens with."
            )
            .font(.caption).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    func seedVR2FormContent(models: ComfyModelStore) -> some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 0) {
            seedVR2Header
            Divider()
            seedVR2Form(settings: settings, models: models)
        }
    }

    private func seedVR2Form(settings: AppSettings, models: ComfyModelStore) -> some View {
        @Bindable var settings = settings
        let remote = settings.comfyBackendEnabled[ModelFamily.seedvr2.id] == true
        return Form {
            comfyBackendPicker(family: .seedvr2)

            if remote {
                Section {
                    comfyServerRow(models: models)
                    seedVR2ServerFile(label: "3B", models: models, is7B: false)
                    seedVR2ServerFile(label: "7B", models: models, is7B: true)
                } footer: {
                    Text(
                        "Runs on ComfyUI's built-in SeedVR2 nodes, with model files picked from the server. Scale, softness, "
                            + "model size and seed carry over unchanged; quantize doesn't apply, since the server file sets the precision."
                    )
                    .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Section("Upscale defaults") {
                Picker("Model", selection: $settings.seedVR2Use7B) {
                    Text("3B — fast").tag(false)
                    Text("7B — quality").tag(true)
                }
                Picker("Quantize", selection: $settings.seedVR2Quantize) {
                    Text("None").tag(0)
                    Text("8-bit").tag(8)
                    Text("4-bit").tag(4)
                }
                .disabled(remote)
                Picker("Scale", selection: $settings.seedVR2Scale) {
                    Text("2×").tag(2)
                    Text("3×").tag(3)
                    Text("4×").tag(4)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Softness")
                        Spacer()
                        Text(String(format: "%.2f", settings.seedVR2Softness))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $settings.seedVR2Softness, in: 0 ... 1, step: 0.05)
                }
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings.seedVR2Use7B = false
                    settings.seedVR2Quantize = 8
                    settings.seedVR2Scale = 2
                    settings.seedVR2Softness = 0.0
                }
                .foregroundStyle(.red)
                .accessibilityLabel("Reset SeedVR2 to built-in defaults")
            }
        }
        .formStyle(.grouped)
    }

    /// Which server file a remote upscale at this size would load, from the discovered loader options.
    private func seedVR2ServerFile(label: String, models: ComfyModelStore, is7B: Bool) -> some View {
        LabeledContent(label) {
            if let files = ComfyUIClient.pickSeedVR2Files(unets: models.unets, vaes: models.vaes, is7B: is7B) {
                Text(files.unet).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else if case .loaded = models.status {
                Text("Not found on server").font(.caption).foregroundStyle(.red)
            } else {
                Text("—").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
