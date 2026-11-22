import SwiftUI

/// The Models window: every model under its family, with what is cached.
struct ModelManagerView: View {
    static let windowID = "model-manager"

    @Environment(AppSettings.self) private var settings
    @Environment(WeightDownloadStore.self) private var weightDownloads
    @Environment(ModelManagerRouter.self) private var router
    @Environment(ModelDownloadStore.self) private var modelDownloads

    /// mflux's SeedVR2 download specs, probed once per window appearance.
    @State private var seedVR2Specs: [String: HFDownloadSpec]?
    @State private var seedVR2Probing = true
    @State private var diskBytes: Int64 = 0

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            List(selection: $router.selection) {
                ForEach(ModelInventory.sections) { section in
                    Section(section.title) {
                        ForEach(section.models, id: \.self) { model in
                            ModelManagerListRow(row: row(for: model), isDownloading: isDownloading(model))
                                .tag(ModelManagerRouter.Item.model(model))
                        }
                    }
                }
                Section("Tools") {
                    toolRow("SeedVR2", chips: seedVR2Chips).tag(ModelManagerRouter.Item.seedVR2)
                    toolRow("Gemma", chips: gemmaCached ? ["✓"] : []).tag(ModelManagerRouter.Item.gemma)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ModelManagerFooter(hubDir: settings.hfHubDir, bytes: diskBytes)
            }
        } detail: {
            detail
        }
        .frame(minWidth: 640, minHeight: 420)
        .task(id: "\(weightDownloads.revision) \(settings.hfHubDir.path)") {
            await HFCacheVerdictStore.shared.refresh(settings: settings)
        }
        .task {
            let python = try? settings.toolchain.mfluxInterpreter()
            let script = Bundle.main.url(forResource: "hf_cache_probe", withExtension: "py")
            let names = SeedVR2DetailView.sizes.map(\.name)
            seedVR2Specs = await Task.detached {
                script.flatMap { MfluxProbes.downloadSpecs(python: python, script: $0, names: names) }
            }.value
            seedVR2Probing = false
        }
        .task(id: diskKey) {
            let hubDir = settings.hfHubDir
            let seedVR2Repo = seedVR2Specs?.values.first?.repo
            let gemmaRepo = FileAccessPath.isLocal(settings.gemmaModel) ? nil : settings.gemmaModel
            let folders = ModelInventory.listedRepoFolders(hubDir: hubDir, seedVR2Repo: seedVR2Repo, gemmaRepo: gemmaRepo)
            diskBytes = await Task.detached { ModelInventory.diskBytes(repoFolders: folders) }.value
        }
        .onDisappear { weightDownloads.dismissFinished() }
        .onChange(of: router.selection) { old, _ in
            if case let .model(previous)? = old {
                weightDownloads.dismissFinished(previous)
            } else if case .seedVR2? = old {
                weightDownloads.dismissFinishedSeedVR2()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch router.selection {
        case let .model(model): ModelManagerDetailView(model: model).id(model)
        case .seedVR2: SeedVR2DetailView(specs: seedVR2Specs, loading: seedVR2Probing)
        case .gemma: GemmaDetailView()
        case nil: EmptyView()
        }
    }

    private var seedVR2Chips: [String] {
        SeedVR2DetailView.sizes.compactMap { size in
            let cached = seedVR2Specs?[size.name].map { ModelInventory.isCached($0, hubDir: settings.hfHubDir) } ?? false
            return cached ? size.label : nil
        }
    }

    private var diskKey: String {
        let repo = seedVR2Specs?.values.first?.repo ?? ""
        return "\(weightDownloads.revision) \(settings.hfHubDir.path) \(repo) \(settings.gemmaModel) \(gemmaDownloading)"
    }

    /// Flips when a Gemma fetch starts or ends, so the chip and disk total recompute.
    private var gemmaDownloading: Bool {
        modelDownloads.active[settings.gemmaModel] != nil
    }

    private var gemmaCached: Bool {
        _ = gemmaDownloading
        return !FileAccessPath.isLocal(settings.gemmaModel)
            && ModelDownloadStore.hasCachedWeights(repo: settings.gemmaModel, hubDir: settings.hfHubDir)
    }

    private func toolRow(_ title: String, chips: [String]) -> some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            ForEach(chips, id: \.self) { chip in
                CachedChip(label: chip)
            }
        }
    }

    private func row(for model: FluxModelVariant) -> ModelRow {
        settings.inventoryRow(for: model)
    }

    private func isDownloading(_ model: FluxModelVariant) -> Bool {
        weightDownloads.runs.contains { target, run in
            if case let .weights(variant, _) = target {
                return variant == model && run.phase == .running
            }
            return false
        }
    }
}
