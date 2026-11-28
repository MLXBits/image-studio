import SwiftUI

/// Per-model settings form. Shows inside the Settings "Models" tab.
///
/// The form bodies live in `ModelDefaultsView+Forms` and the reusable field
/// builders in `ModelDefaultsView+Fields`; both reach `settings` (internal here)
/// and the shared helpers. Downloads and removal live in the Models window.
struct ModelDefaultsView: View {
    /// Sidebar selection: a generative FLUX/Ideogram/Krea model, or the SeedVR2
    /// upscaler (which isn't a ``FluxModelVariant``).
    enum Selection: Hashable {
        case model(FluxModelVariant)
        case seedVR2
    }

    @Environment(AppSettings.self) var settings
    @Environment(ModelManagerRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Selection = .model(.builtIn[0])

    /// The selected FLUX model, or the first built-in as a placeholder while the
    /// SeedVR2 row is selected (its form doesn't read this).
    private var selectedModel: FluxModelVariant {
        if case let .model(model) = selection {
            return model
        }
        return .builtIn[0]
    }

    /// Discovered ComfyUI model lists, bound to the remote-capable forms. Owned by ``SettingsView``, which shares it with the LoRAs tab.
    @Environment(ComfyModelStore.self) private var comfyModels

    var body: some View {
        HStack(spacing: 0) {
            // Left: model list
            modelList
                .frame(width: 160)
            Divider()
            // Right: settings for selected model
            modelForm
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: settings.comfyURL) { _, newURL in
            let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                comfyModels.cancel()
            } else {
                comfyModels.refresh(baseURL: trimmed)
            }
        }
        .onChange(of: settings.comfyBackendEnabled) { _, _ in
            let trimmed = settings.comfyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                comfyModels.cancel()
            } else {
                comfyModels.refresh(baseURL: trimmed)
            }
        }
    }

    // MARK: - Model list

    private var modelList: some View {
        List(selection: $selection) {
            Section("FLUX 3") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(FluxModelVariant.flux3Klein.displayName).font(.callout)
                    Text("Distilled · \(FluxModelVariant.flux3Klein.defaultSteps) steps")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(Selection.model(.flux3Klein))
                VStack(alignment: .leading, spacing: 2) {
                    Text(FluxModelVariant.flux3KleinBase.displayName).font(.callout)
                    Text("Base · \(FluxModelVariant.flux3KleinBase.defaultSteps) steps")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(Selection.model(.flux3KleinBase))
            }
            Section("FLUX.2") {
                ForEach(FluxModelVariant.builtIn, id: \.self) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName).font(.callout)
                        Text(model.isDistilled
                            ? "Distilled · \(model.defaultSteps) steps"
                            : "Base · \(model.defaultSteps) steps")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(Selection.model(model))
                }
            }
            Section("Ideogram") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ideogram 4").font(.callout)
                    Text("Preset-based · BF16/Q8/Q4")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(Selection.model(.ideogram4))
            }
            Section("Krea") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Krea 2 Turbo").font(.callout)
                    Text("Turbo · \(FluxModelVariant.krea2.defaultSteps) steps · BF16/Q8/Q4")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(Selection.model(.krea2))
            }
            Section("Qwen") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(FluxModelVariant.qwen21Turbo.displayName).font(.callout)
                    Text("Turbo · \(FluxModelVariant.qwen21Turbo.defaultSteps) steps · Generate + Edit · BF16/Q8/Q4")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(Selection.model(.qwen21Turbo))
            }
            Section("Z-Image") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Z-Image Turbo").font(.callout)
                    Text("Turbo · \(FluxModelVariant.zimageTurbo.defaultSteps) steps · BF16/Q8/Q4")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(Selection.model(.zimageTurbo))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Z-Image").font(.callout)
                    Text("Base · \(FluxModelVariant.zimage.defaultSteps) steps · BF16/Q8/Q4")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(Selection.model(.zimage))
            }
            Section("Upscale") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SeedVR2").font(.callout)
                    Text("Image action · 3B/7B · BF16/Q8/Q4")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(Selection.seedVR2)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Per-model form

    @ViewBuilder
    private var modelForm: some View {
        if case .seedVR2 = selection {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    manageDownloadsButton.padding([.horizontal, .top])
                    seedVR2FormContent(models: comfyModels)
                }
            }
            .task { await ensureComfyDiscovery() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    modelHeader
                    Divider()
                    if selectedModel.isIdeogram4 {
                        ideogram4FormContent()
                    } else if selectedModel.isKrea2 {
                        krea2FormContent(models: comfyModels)
                            .task { await ensureComfyDiscovery() }
                    } else if selectedModel.isZImage {
                        zimageFormContent(model: selectedModel)
                    } else if selectedModel.isQwen21 {
                        qwen21FormContent(models: comfyModels)
                            .task { await ensureComfyDiscovery() }
                    } else if FluxModelVariant.builtIn.contains(selectedModel) {
                        flux2FormContent(model: selectedModel, defaults: settings.defaults(for: selectedModel), models: comfyModels)
                            .task { await ensureComfyDiscovery() }
                    } else {
                        formContent(model: selectedModel, defaults: settings.defaults(for: selectedModel))
                    }
                }
            }
        }
    }

    private var modelHeader: some View {
        let quantize: Int
        let typeLabel: String
        if selectedModel.isIdeogram4 {
            quantize = settings.defaults(for: .ideogram4).quantize ?? 8
            typeLabel = "Preset-based"
        } else {
            quantize = settings.defaults(for: selectedModel).quantize ?? selectedModel.recommendedQuantize
            typeLabel = selectedModel.isStepDistilled ? "Distilled" : "Base model"
        }
        let vramGB = selectedModel.approximateRAMGB(quantize: quantize, settings: settings)
        let quantLabel = quantize == 0 ? selectedModel.baseWeightLabel : "Q\(quantize)"
        let vramColor = RAMFit.of(ramGB: vramGB, physicalGB: RAMFit.physicalGB).color

        return VStack(alignment: .leading, spacing: 6) {
            Text(selectedModel.displayName)
                .font(.headline)

            HStack(spacing: 10) {
                Label(
                    typeLabel,
                    systemImage: selectedModel.isStepDistilled ? "bolt.fill" : "cpu"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if vramGB > 0 {
                    Label(
                        "≈\(String(format: "%.0f", vramGB)) GB with \(quantLabel)",
                        systemImage: "memorychip"
                    )
                    .font(.caption)
                    .foregroundStyle(vramColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(vramColor.opacity(0.1), in: Capsule())
                }
            }

            manageDownloadsButton

            if selectedModel.isIdeogram4 {
                // Single string literal (no `+`) so the markdown links render and stay
                // clickable. The mflux-community Q8/Q4 repos are gated, each on its own
                // card; the BF16 one is not.
                Text("""
                Q8 and Q4 are gated — accept access on each repo, then set your HF token in \
                Settings → Advanced. \
                Q8: [mflux-community/ideogram-4-mflux-q8](https://huggingface.co/mflux-community/ideogram-4-mflux-q8). \
                Q4: [mflux-community/ideogram-4-mflux-q4](https://huggingface.co/mflux-community/ideogram-4-mflux-q4).
                """)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .tint(.accentColor)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(
                    "Overrides global defaults when this model is selected."
                        + " The memory estimate above reflects your current quantize setting."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }

    /// Opens the Models window on the selected row; downloads and removal live there.
    private var manageDownloadsButton: some View {
        Button("Manage Downloads…") {
            switch selection {
            case .seedVR2: router.show(.seedVR2, open: openWindow)
            case let .model(model): router.show(.model(model), open: openWindow)
            }
        }
        .controlSize(.small)
    }

    /// Trigger ComfyUI model discovery when a remote-capable form (Krea 2, SeedVR2) appears, but only if some family is in
    /// remote mode with a URL set and lists haven't already loaded for that exact server. This is what populates the pickers
    /// on first open (the `.onChange` handlers alone never fire unless a value actually changes).
    private func ensureComfyDiscovery() async {
        guard settings.comfyBackendEnabled.values.contains(true) else { return }
        let trimmed = settings.comfyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !comfyModels.hasLoaded(for: trimmed) {
            comfyModels.refresh(baseURL: trimmed)
        }
    }
}
