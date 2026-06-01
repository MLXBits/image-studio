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
    var board: String = ""
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

    func makeJob(count: Int = 1) -> FluxJob {
        let seeds: [Int] = count > 1
            ? (0..<count).map { _ in Int(UInt32.random(in: 0..<UInt32.max)) }
            : []
        return FluxJob(
            model: model,
            customModelRepo: customModelRepo,
            customBaseModel: customBaseModel,
            prompt: prompt,
            negativePrompt: negativePrompt,
            width: width,
            height: height,
            seed: seed,
            seeds: seeds,
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
    @State private var fullSizeImage: NSImage? = nil

    private var batchCountBinding: Binding<Int> {
        Binding(get: { params.batchCount }, set: { params.batchCount = $0 })
    }
    @State private var showingParams: Bool = true
    @State private var pendingSelectPath: String? = nil

    var body: some View {
        ZStack {
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
                    },
                    onShowFullSize: { img in
                        withAnimation(.easeInOut(duration: 0.2)) { fullSizeImage = img }
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
            .safeAreaInset(edge: .top, spacing: 0) {
                topControlBar
            }

            if let img = fullSizeImage {
                FullSizeImageView(image: img, onDismiss: {
                    withAnimation(.easeInOut(duration: 0.2)) { fullSizeImage = nil }
                })
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showingParams.toggle() } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.leading")
                }
                .help("Toggle params panel")
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
                if selectedGalleryItem == nil {
                    previewState = runner.activeJob.map { .activeJob($0) } ?? .idle
                }
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
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onChange(of: settings.defaultLoras) { _, updated in
            let notesByPath = Dictionary(uniqueKeysWithValues: updated.compactMap { e -> (String, String)? in
                e.notes.isEmpty ? nil : (e.path, e.notes)
            })
            for i in params.loras.indices where notesByPath[params.loras[i].path] != nil {
                params.loras[i].notes = notesByPath[params.loras[i].path]!
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
        .onChange(of: runner.batchImageLanded) { _, count in
            guard count > 1 else { return }  // first image handled by lastCompletedOutputPath
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

    // MARK: - Top control bar

    private var topControlBar: some View {
        HStack(spacing: 0) {
            Spacer()
            HStack(spacing: 12) {
                let canGenerate = !params.prompt.trimmingCharacters(in: .whitespaces).isEmpty
                Button(action: generate) {
                    Label("Generate  ⌘↵", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .focusEffectDisabled()
                .disabled(!canGenerate)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Generate (⌘↵)")

                HStack(spacing: 4) {
                    PassiveTextField(
                        value: batchCountBinding,
                        format: .number,
                        onSubmit: { params.batchCount = max(1, min(99, params.batchCount)) }
                    )
                    .frame(width: 46, height: 22)
                    Stepper("", value: batchCountBinding, in: 1...99)
                        .labelsHidden()
                        .focusEffectDisabled()
                }
                .help("Number of images to queue")

                Divider().frame(height: 18)

                Button { showingQueue.toggle() } label: {
                    queueStatusLabel
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(store.isRunning ? "Generating — click to view queue (⌘K)" : "Show queue (⌘K)")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private var queueStatusLabel: some View {
        if store.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let job = runner.activeJob, job.seeds.count > 1 {
                    let done = job.completedSeedsInBatch
                    let total = job.seeds.count
                    Text("\(done)/\(total) images")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    let remaining = store.pendingJobs.count + 1
                    Text("\(remaining) left")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Label("Queue", systemImage: "list.bullet")
        }
    }

    // MARK: - Generate

    private func generate() {
        guard !params.prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        settings.lastPrompt = params.prompt
        let job = params.makeJob(count: params.batchCount)
        store.add(job)
        if runner.activeJob == nil {
            selectedGalleryItem = nil
            previewState = .activeJob(job)
        }
        runner.runNext(in: store, settings: settings)
    }
}
