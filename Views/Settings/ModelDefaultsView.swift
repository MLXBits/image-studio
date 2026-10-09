import SwiftUI

/// Per-model settings form. Shows inside the Settings "Models" tab.
///
/// The form bodies live in `ModelDefaultsView+Forms` and the reusable field
/// builders in `ModelDefaultsView+Fields`; both reach `settings` (internal here)
/// and the shared helpers. Downloads belong to ``WeightDownloadStore``.
struct ModelDefaultsView: View {
    /// Sidebar selection: a generative FLUX/Ideogram/Krea model, or the SeedVR2
    /// upscaler (which isn't a ``FluxModelVariant`` and has no weight-cache rows).
    enum Selection: Hashable {
        case model(FluxModelVariant)
        case seedVR2
    }

    @Environment(AppSettings.self) var settings
    @Environment(LoraLibraryStore.self) private var loraLibrary
    @Environment(WeightDownloadStore.self) private var weightDownloads
    @State private var selection: Selection = .model(.builtIn[0])

    /// The selected FLUX model, or the first built-in as a placeholder while the
    /// SeedVR2 row is selected (its form doesn't read this).
    private var selectedModel: FluxModelVariant {
        if case let .model(model) = selection {
            return model
        }
        return .builtIn[0]
    }

    /// Changes when weights are deleted here; downloads bump the store's revision.
    @State private var cacheRevision = UUID()
    @State private var pendingDeleteVariant: (model: FluxModelVariant, quantize: Int)?
    /// Discovered ComfyUI model lists, bound to the Krea 2 and SeedVR2 forms. Refreshed when a server URL is set.
    @State private var comfyModels = ComfyModelStore()
    /// True once the auto-catalog callback has been wired for this view instance, so `.onAppear` doesn't re-install it on every appearance
    /// (the closure captures `loraLibrary`; one install per live store is enough and idempotent cataloging makes re-runs harmless anyway).
    @State private var catalogWired = false

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
        .onAppear {
            guard !catalogWired else { return }
            catalogWired = true
            // Race-free auto-cataloging: the store invokes this in the same task that stores `info.loras` after a
            // successful discovery pass, so the library is updated before any picker observes it. Idempotent inside the
            // store (deduped by path), so repeated discoveries never clobber user edits to existing entries.
            comfyModels.onLorasDiscovered = { names in
                loraLibrary.catalogServerLoras(names: names)
            }
        }
        // Ask mflux which models are downloaded (#19) on open, after each
        // download or deletion, and when the models folder moves.
        .task(id: "\(cacheRevision) \(weightDownloads.revision) \(settings.hfHubDir.path)") {
            await HFCacheVerdictStore.shared.refresh(settings: settings)
        }
        // Leaving a page clears its finished row and log; a download keeps going (#27).
        .onChange(of: selection) { old, _ in
            if case let .model(model) = old {
                weightDownloads.dismiss(model)
            }
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
        .alert("Delete cached weights?", isPresented: Binding(
            get: { pendingDeleteVariant != nil },
            set: {
                if !$0 {
                    pendingDeleteVariant = nil
                }
            }
        )) {
            Button("Delete", role: .destructive) {
                if let pending = pendingDeleteVariant {
                    deleteCachedVariant(model: pending.model, quantize: pending.quantize)
                }
                pendingDeleteVariant = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteVariant = nil }
        } message: {
            if let pending = pendingDeleteVariant {
                let qLabel = pending.quantize == 0 ? pending.model.baseWeightLabel : "Q\(pending.quantize)"
                Text(
                    "This will permanently delete the \(qLabel) weights for"
                        + " \(pending.model.displayName) from disk. You can re-download them later."
                )
            }
        }
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

    // MARK: - Model list

    private var modelList: some View {
        List(selection: $selection) {
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
                    Text("Preset-based · gated · FP8/Q8/Q4")
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
            ScrollView { seedVR2FormContent(models: comfyModels) }
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
            quantize = settings.lastIdeogramQuantize ?? 8
            typeLabel = "Preset-based"
        } else {
            quantize = settings.defaults(for: selectedModel).quantize ?? selectedModel.recommendedQuantize
            typeLabel = selectedModel.isDistilled ? "Distilled" : "Base model"
        }
        let vramGB = selectedModel.approximateSizeGB(quantize: quantize)
        let quantLabel = quantize == 0 ? selectedModel.baseWeightLabel : "Q\(quantize)"
        let vramColor: Color = vramGB > 30 ? .orange : vramGB > 18 ? .yellow : .green

        return VStack(alignment: .leading, spacing: 6) {
            Text(selectedModel.displayName)
                .font(.headline)

            HStack(spacing: 10) {
                Label(
                    typeLabel,
                    systemImage: selectedModel.isDistilled ? "bolt.fill" : "cpu"
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

            cacheStatusRow(model: selectedModel)

            if let run = weightDownloads.runs[selectedModel] {
                cacheLogView(run)
            }

            if selectedModel.isIdeogram4 {
                // Single string literal (no `+`) so the markdown links render and stay
                // clickable. FP8 is Ideogram's gated repo; Q8/Q4 are the mflux-community
                // mflux-save conversions, each gated on their own card.
                Text("""
                Gated — accept access on each source repo, then set your HF token in \
                Settings → Advanced. \
                FP8: [ideogram-ai/ideogram-4-fp8](https://huggingface.co/ideogram-ai/ideogram-4-fp8). \
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

    // MARK: - Cache log

    private func cacheLogView(_ run: WeightDownloadStore.Run) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(run.log.isEmpty ? "Starting…" : run.log)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("cacheLogEnd")
            }
            .frame(height: 120)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: run.log) { _, _ in proxy.scrollTo("cacheLogEnd") }
            .onAppear { proxy.scrollTo("cacheLogEnd") }
        }
    }

    @ViewBuilder
    private func cacheStatusRow(model: FluxModelVariant) -> some View {
        switch weightDownloads.runs[model]?.phase {
        case .running:
            if let run = weightDownloads.runs[model] {
                runningRow(run)
            }

        case let .failed(message):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Label("Failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                    Button("Retry") {
                        if let run = weightDownloads.runs[model] {
                            weightDownloads.start(model: model, quantize: run.quantize, settings: settings)
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Spacer()
                }
                Text(message)
                    .font(.caption2).foregroundStyle(.red.opacity(0.8))
            }

        case nil, .done:
            HStack(spacing: 6) {
                // swiftlint:disable:next redundant_discardable_let
                let _ = (cacheRevision, weightDownloads.revision) // invalidates view when cache changes on disk
                let cachedVariants = [0, 4, 8].filter {
                    model.isOnDisk(quantize: $0, savedIn: settings.effectiveMfluxCacheDir, hubDir: settings.hfHubDir)
                }
                ForEach(cachedVariants, id: \.self) { qLevel in
                    HStack(spacing: 3) {
                        Text(qLevel == 0 ? model.baseWeightLabel : "Q\(qLevel)")
                            .font(.caption2).fontWeight(.medium)
                        Button {
                            pendingDeleteVariant = (model, qLevel)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        // Compact so the target stays inside the capsule chip. This
                        // deletes cached weights — it was a 7pt glyph before.
                        .buttonStyle(.iconButtonCompact)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
                }
                let cacheDir = settings.effectiveMfluxCacheDir
                ForEach(
                    [0, 4, 8].filter { !model.isOnDisk(quantize: $0, savedIn: cacheDir, hubDir: settings.hfHubDir) },
                    id: \.self
                ) { qLevel in
                    let qLabel = qLevel == 0 ? model.baseWeightLabel : "Q\(qLevel)"
                    Button("Download \(qLabel)") {
                        weightDownloads.start(model: model, quantize: qLevel, settings: settings)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
            }
        }
    }

    private func deleteCachedVariant(model: FluxModelVariant, quantize: Int) {
        let savePath = model.savedModelPath(quantize: quantize, in: settings.effectiveMfluxCacheDir)
        try? FileManager.default.removeItem(at: savePath)
        if let hfURL = model.onDiskURL(quantize: quantize, hubDir: settings.hfHubDir) {
            try? FileManager.default.removeItem(at: hfURL)
        }
        cacheRevision = UUID()
    }

    private func runningRow(_ run: WeightDownloadStore.Run) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                // Only an mflux-save pass from base weights already on disk is a
                // conversion; a pass that fetches them downloads first.
                let converting: Bool = {
                    guard case .save = run.plan, run.quantize != 0 else { return false }
                    return run.model.isOnDisk(quantize: 0, savedIn: settings.effectiveMfluxCacheDir, hubDir: settings.hfHubDir)
                }()
                let verb = converting ? "Converting" : "Downloading"
                // hf download emits noisy parallel progress bars that don't render
                // well in a plain log, so poll the on-disk payload for live feedback.
                TimelineView(.periodic(from: run.startedAt, by: 1)) { ctx in
                    let elapsed = Int(ctx.date.timeIntervalSince(run.startedAt))
                    let mm = elapsed / 60
                    let ss = elapsed % 60
                    let time = "\(mm > 0 ? "\(mm)m " : "")\(String(format: "%02d", ss))s"
                    Text("\(verb)… \(time)\(downloadedSuffix(run))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { weightDownloads.cancel(run.model) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Text("You can close Settings — this continues in the background.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// " · 4.4 / 27 GB" while the run's download is landing, polled from its blobs
    /// dir (includes in-flight `.incomplete` files). Empty when it downloads nothing
    /// or no bytes have landed yet.
    private func downloadedSuffix(_ run: WeightDownloadStore.Run) -> String {
        guard let target = WeightDownloadStore.progressTarget(of: run, hubDir: settings.hfHubDir) else { return "" }
        let bytes = ModelDownloadStore.blobBytes(in: target.folder)
        guard bytes > 0 else { return "" }
        let gb = Double(bytes) / 1_073_741_824
        return target.totalGB > 0
            ? " · \(String(format: "%.1f", gb)) / \(String(format: "%.0f", target.totalGB)) GB"
            : " · \(String(format: "%.1f", gb)) GB"
    }
}
