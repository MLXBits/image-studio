import SwiftUI

/// The Models window: every model under its family, with what is cached.
struct ModelManagerView: View {
    static let windowID = "model-manager"

    @Environment(AppSettings.self) private var settings
    @Environment(WeightDownloadStore.self) private var weightDownloads
    @Environment(ModelManagerRouter.self) private var router

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
                    Text("SeedVR2").tag(ModelManagerRouter.Item.seedVR2)
                    Text("Gemma").tag(ModelManagerRouter.Item.gemma)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            detail
        }
        .frame(minWidth: 640, minHeight: 420)
        .task(id: "\(weightDownloads.revision) \(settings.hfHubDir.path)") {
            await HFCacheVerdictStore.shared.refresh(settings: settings)
        }
        .onDisappear { weightDownloads.dismissFinished() }
        .onChange(of: router.selection) { old, _ in
            if case let .model(previous)? = old {
                weightDownloads.dismissFinished(previous)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch router.selection {
        case let .model(model): ModelManagerDetailView(model: model).id(model)
        case .seedVR2: Text("SeedVR2")
        case .gemma: Text("Gemma")
        case nil: EmptyView()
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
