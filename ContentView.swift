import SwiftUI

@Observable
final class ParamsPanelState {
    var model: FluxModelVariant = .flux2Klein9B
    var customModelRepo: String = ""
    var customBaseModel: FluxModelVariant = .flux2Klein9B
    var prompt: String = ""
    var negativePrompt: String = ""
    var width: Int = 1024
    var height: Int = 1024
    var seed: Int = -1
    var steps: Int = 4
    var guidance: Double = 1.0
    var quantize: Int = 8
    var lowRam: Bool = false
    var loras: [LoraEntry] = []
    var imagePath: String = ""
    var imageStrength: Double = 0.75
    var board: String = "Default"
    var batchCount: Int = 1

    func applyDefaults(from settings: AppSettings) {
        model    = settings.defaultModel
        quantize = settings.defaultQuantize
        board    = settings.defaultBoard
        width    = settings.defaultWidth
        height   = settings.defaultHeight
        steps    = settings.defaultSteps
        guidance = settings.defaultGuidance
        seed     = settings.defaultSeed
        lowRam   = settings.defaultLowRam
        loras    = settings.defaultLoras
    }

    func apply(metadata meta: GenerationMetadata, newSeed: Bool) {
        model           = meta.model
        customModelRepo = meta.customModelRepo
        customBaseModel = meta.customBaseModel
        prompt          = meta.prompt
        negativePrompt  = meta.negativePrompt
        width           = meta.width
        height          = meta.height
        steps           = meta.steps
        guidance        = meta.guidance
        quantize        = meta.quantize
        lowRam          = meta.lowRam
        imagePath       = meta.imagePath
        imageStrength   = meta.imageStrength
        loras           = meta.loras
        seed            = newSeed ? -1 : meta.seed
    }

    func makeJob() -> FluxJob {
        FluxJob(
            model: model,
            customModelRepo: customModelRepo,
            customBaseModel: customBaseModel,
            prompt: prompt,
            negativePrompt: negativePrompt,
            width: width,
            height: height,
            seed: seed,
            steps: steps,
            guidance: guidance,
            loras: loras,
            quantize: quantize,
            lowRam: lowRam,
            imagePath: imagePath,
            imageStrength: imageStrength,
            board: board
        )
    }
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobStore.self) private var store
    @Environment(FluxJobRunner.self) private var runner
    @Environment(GalleryStore.self) private var gallery

    @State private var previewState: PreviewState = .idle
    @State private var selectedGalleryItem: GalleryItem? = nil
    @State private var showingSettings: Bool = false
    @State private var showingQueue: Bool = false
    @State private var params = ParamsPanelState()

    var body: some View {
        NavigationSplitView {
            ParamsPanelView(params: params, onGenerate: generate)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } content: {
            PreviewPaneView(
                state: previewState,
                onRemix: { meta in params.apply(metadata: meta, newSeed: true) },
                onUseInImg2Img: { path in params.imagePath = path },
                onCancel: { runner.cancel() }
            )
        } detail: {
            GenerationGalleryView(
                selectedItem: $selectedGalleryItem,
                onRemix: { meta in params.apply(metadata: meta, newSeed: true) },
                onUseInImg2Img: { path in params.imagePath = path }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 360)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showingQueue.toggle() } label: {
                    Label("Queue", systemImage: "list.bullet")
                }
                .help("Show queue (⌘K)")
            }

            ToolbarItem(placement: .automatic) {
                if store.isRunning {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button { showingSettings = true } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environment(settings)
        }
        .sheet(isPresented: $showingQueue) {
            queueSheet
        }
        .onChange(of: runner.activeJob?.id) { _, id in
            guard let id, let job = store.jobs.first(where: { $0.id == id }) else { return }
            previewState = .activeJob(job)
        }
        .onChange(of: selectedGalleryItem?.id) { _, id in
            guard let id, let item = gallery.items.first(where: { $0.id == id }) else {
                if selectedGalleryItem == nil { /* keep preview */ }
                return
            }
            previewState = .galleryItem(item)
        }
        .background {
            Button("") { generate() }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
            Button("") { showingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
            Button("") { showingQueue.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .onAppear {
            params.applyDefaults(from: settings)
            gallery.scan(outputDir: settings.outputDir)
        }
    }

    private var queueSheet: some View {
        NavigationStack {
            QueueDrawerView(selectedJob: Binding(
                get: {
                    if case .activeJob(let j) = previewState { return j }
                    return nil
                },
                set: { job in
                    if let j = job { previewState = .activeJob(j) }
                }
            ))
            .environment(store)
            .environment(runner)
            .environment(settings)
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingQueue = false }
                }
            }
        }
        .frame(width: 360, height: 500)
    }

    // MARK: - Generate

    private func generate() {
        guard !params.prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let jobs = (0..<params.batchCount).map { _ in params.makeJob() }
        store.addBatch(jobs)
        if let first = jobs.first {
            previewState = .activeJob(first)
        }
        runner.runNext(in: store, settings: settings)
        // Rescan gallery after current run
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            gallery.scan(outputDir: settings.outputDir)
        }
    }
}
