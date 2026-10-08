import SwiftUI

// MARK: - Krea 2 per-model form body
//
// Krea 2 Turbo is text-to-image with CFG. It exposes only the controls the dev
// `mflux-generate-krea2` CLI backstops: steps, guidance, quantize, canvas,
// model source, low-RAM streaming, and LoRAs.

extension ModelDefaultsView {
    func krea2FormContent(models: ComfyModelStore) -> some View {
        let model = FluxModelVariant.krea2
        let d = settings.defaults(for: model)
        return Form {
            comfyBackendPicker(family: .krea2)

            if settings.comfyBackendEnabled[ModelFamily.krea2.id] == true {
                Section {
                    comfyServerRow(models: models)

                    comfyFileRow("UNet model", \.comfyUNet, options: models.unets, placeholder: "krea2_turbo_fp8_scaled.safetensors")
                    comfyFileRow("CLIP encoder", \.comfyClip, options: models.clips, placeholder: "qwen3vl_4b_fp8_scaled.safetensors")
                    comfyFileRow("VAE", \.comfyVae, options: models.vaes, placeholder: "qwen_image_vae.safetensors")
                } footer: {
                    Text(
                        "Runs on the remote box using these files. Local mflux and this config are saved independently, " +
                            "so switching back never loses either."
                    )
                    .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Section {
                if (settings.comfyBackendEnabled[ModelFamily.krea2.id] ?? false) == false {
                    stepsPicker(model: model, current: d.steps)
                    guidancePicker(model: model, current: d.guidance)
                    quantizePicker(model: model, current: d.quantize)
                    modelRepoField(model: model, current: d.modelRepoOverride)
                    lowRamToggle(model: model, current: d.lowRam)
                } else {
                    Text(
                        "Steps, guidance, and LoRAs are sent to the server per job from the Krea 2 params panel — " +
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
                .accessibilityLabel("Reset Krea 2 Turbo to built-in defaults")
            }
        }
        .formStyle(.grouped)
        .id(model)
    }
}

// MARK: - ComfyUI model picker (live-discovered lists, manual-entry fallback)

extension ModelDefaultsView {
    /// The mflux / ComfyUI segment for one family. It sits at the top of the form, not in a section header (a Picker styled
    /// as segmented can't host a custom trailing refresh control cleanly). mflux is first/default.
    func comfyBackendPicker(family: ModelFamily) -> some View {
        Picker("Inference backend", selection: Binding(
            get: { settings.comfyBackendEnabled[family.id] ?? false },
            set: { settings.comfyBackendEnabled[family.id] = $0 }
        )) {
            Text("mflux (local)").tag(false)
            Text("ComfyUI").tag(true)
        }
        .pickerStyle(.segmented)
    }

    /// Server URL + refresh on one row, discovery status underneath. The URL is shared by every ComfyUI-routed family.
    func comfyServerRow(models: ComfyModelStore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("http://192.168.x.x:8188", text: Binding(
                    get: { settings.comfyURL },
                    set: { settings.comfyURL = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .autocorrectionDisabled()
                Button {
                    let trimmed = settings.comfyURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        models.refresh(baseURL: trimmed)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.iconButtonCompact)
                .help("Re-discover available model files on the server")
            }
            comfyStatus(models: models)
        }
    }

    /// One Krea 2 server file: the label on its own line above the picker, so long filenames never wrap inconsistently.
    func comfyFileRow(
        _ label: String, _ map: ReferenceWritableKeyPath<AppSettings, [String: String]>, options: [String], placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            comfyPicker(
                value: Binding(
                    get: { settings[keyPath: map][ModelFamily.krea2.id] ?? "" },
                    set: { settings[keyPath: map][ModelFamily.krea2.id] = $0 }
                ),
                options: options,
                placeholder: placeholder
            )
        }
    }

    /// A picker for a server-side model file. Shows a menu of the discovered `options` when available;
    /// otherwise falls back to a free-text field so a custom/undiscovered filename still works. The current
    /// value is preserved even if it isn't in the list (e.g. typed manually or from a different server).
    @ViewBuilder
    func comfyPicker(value: Binding<String>, options: [String], placeholder: String) -> some View {
        if !options.isEmpty {
            Menu {
                ForEach(options, id: \.self) { name in
                    Button(name) { value.wrappedValue = name }
                        .fontWeight(value.wrappedValue == name ? .semibold : .regular)
                }
            } label: {
                Text(value.wrappedValue.isEmpty ? placeholder : value.wrappedValue)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(value.wrappedValue.isEmpty ? .secondary : .primary)
                    .frame(width: 320, alignment: .leading)
            }
            .menuStyle(.button)
        } else {
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .autocorrectionDisabled()
        }
    }

    /// One-line status under the ComfyUI section header's models: discovery state + refresh affordance.
    func comfyStatus(models: ComfyModelStore) -> some View {
        HStack(spacing: 6) {
            switch models.status {
            case .idle:
                Text("Enter a URL to discover available models.")
                    .font(.caption).foregroundStyle(.secondary)
            case .loading:
                ProgressView().controlSize(.small)
                Text("Discovering…")
                    .font(.caption).foregroundStyle(.secondary)
            case let .loaded(count):
                Text("\(count) model files found.")
                    .font(.caption).foregroundStyle(.secondary)
            case let .failed(message):
                Text("Discovery failed: \(message)")
                    .font(.caption).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}
