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
        let m = settings.defaultModel
        let d = settings.resolvedDefaults(for: m)
        model          = m
        quantize       = d.quantize
        board          = settings.defaultBoard
        width          = d.width
        height         = d.height
        steps          = d.steps
        guidance       = d.guidance
        seed           = -1
        lowRam         = d.lowRam
        negativePrompt = d.negativePrompt
        loras          = d.loras.isEmpty ? settings.defaultLoras : d.loras
        prompt         = settings.lastPrompt
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

    @Environment(\.openSettings) private var openSettings

    @State private var previewState: PreviewState = .idle
    @State private var selectedGalleryItem: GalleryItem? = nil
    @State private var showingQueue: Bool = false
    @State private var showingOutputDirPrompt: Bool = false
    @State private var params = ParamsPanelState()
    @State private var showingParams: Bool = true
    @State private var pendingSelectPath: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            if showingParams {
                ParamsPanelView(params: params)
                    .frame(minWidth: 240, idealWidth: 260, maxWidth: 320, maxHeight: .infinity)
                Divider()
            }

            PreviewPaneView(
                state: previewState,
                onRemix: { meta in params.apply(metadata: meta, newSeed: true) },
                onApplySettings: { meta in params.apply(metadata: meta, newSeed: false) },
                onUseInImg2Img: { path in params.imagePath = path },
                onCancel: { runner.cancel() },
                onClear: {
                    selectedGalleryItem = nil
                    if let job = runner.activeJob {
                        previewState = .activeJob(job)
                    } else {
                        previewState = .idle
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            GenerationGalleryView(
                selectedItem: $selectedGalleryItem,
                onRemix: { meta in params.apply(metadata: meta, newSeed: true) },
                onApplySettings: { meta in params.apply(metadata: meta, newSeed: false) },
                onUseInImg2Img: { path in params.imagePath = path },
                onSelectBoard: { name in params.board = name },
                onClearPreview: {
                    selectedGalleryItem = nil
                    if let job = runner.activeJob {
                        previewState = .activeJob(job)
                    } else {
                        previewState = .idle
                    }
                }
            )
            .frame(minWidth: 180, idealWidth: 260, maxWidth: 360, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showingParams.toggle() } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.leading")
                }
                .help("Toggle params panel")
            }

            ToolbarItem(placement: .principal) {
                @Bindable var p = params
                HStack(spacing: 8) {
                    Button(action: generate) {
                        Label("Generate", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(params.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Generate (⌘↵)")

                    Stepper(value: $p.batchCount, in: 1...99) {
                        TextField("", value: $p.batchCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 36)
                            .onSubmit { params.batchCount = max(1, min(99, params.batchCount)) }
                            .focusable(false)
                    }
                    .help("Batch count")

                    Divider().frame(height: 20)

                    Button { showingQueue.toggle() } label: {
                        queueButtonLabel
                    }
                    .help(store.isRunning ? "Generating — click to view queue (⌘K)" : "Show queue (⌘K)")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .sheet(isPresented: $showingQueue) {
            queueSheet
        }
        .onChange(of: runner.activeJob?.id) { _, id in
            guard let id, let job = store.jobs.first(where: { $0.id == id }) else { return }
            selectedGalleryItem = nil
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
            Button("") { showingQueue.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .sheet(isPresented: $showingOutputDirPrompt) {
            OutputDirectoryPromptView(isPresented: $showingOutputDirPrompt)
                .environment(settings)
        }
        .onAppear {
            params.applyDefaults(from: settings)
            if settings.outputDir.isEmpty {
                showingOutputDirPrompt = true
            } else {
                gallery.scan(outputDir: settings.outputDir)
            }
        }
        .onChange(of: showingOutputDirPrompt) { _, showing in
            if !showing, !settings.outputDir.isEmpty {
                gallery.scan(outputDir: settings.outputDir)
            }
        }
        .onChange(of: runner.lastCompletedOutputPath) { _, path in
            pendingSelectPath = path
            gallery.scan(outputDir: settings.outputDir)
        }
        .onChange(of: gallery.items) { _, newItems in
            guard let path = pendingSelectPath,
                  let item = newItems.first(where: { $0.path == path }) else { return }
            selectedGalleryItem = item
            pendingSelectPath = nil
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
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 360, height: 500)
    }

    // MARK: - Queue button

    @ViewBuilder
    private var queueButtonLabel: some View {
        if store.isRunning {
            let pending = store.pendingJobs.count
            HStack(spacing: 6) {
                ProgressView(value: runner.activeJob?.progressFraction ?? 0)
                    .progressViewStyle(.linear)
                    .frame(width: 110)
                    .animation(.linear(duration: 0.25), value: runner.activeJob?.progressFraction)
                if pending > 0 {
                    Text("+\(pending)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .leading)
                }
            }
            .frame(width: 180)
        } else {
            Label("Queue", systemImage: "list.bullet")
                .frame(width: 100)
        }
    }

    // MARK: - Generate

    private func generate() {
        guard !params.prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        settings.lastPrompt = params.prompt
        let jobs = (0..<params.batchCount).map { _ in params.makeJob() }
        store.addBatch(jobs)
        // Don't interrupt a running job's preview; new job goes to queue and will auto-display when it starts.
        if runner.activeJob == nil, let first = jobs.first {
            selectedGalleryItem = nil
            previewState = .activeJob(first)
        }
        runner.runNext(in: store, settings: settings)
    }
}
