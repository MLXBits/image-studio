// swiftlint:disable file_length
import AppKit
import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    private enum MfluxAutoInstall { case idle, installing, done, failed(String) }

    /// Identifies a pending box-overlay editor session (image + its generation dims).
    private struct BoxOverlayContext: Identifiable {
        let id = UUID()
        let image: NSImage
        let width: Int
        let height: Int
    }

    @Environment(AppSettings.self) private var settings
    @Environment(JobStore.self) private var store
    @Environment(FluxJobRunner.self) private var runner
    @Environment(GalleryStore.self) private var gallery
    @Environment(Ideogram4JobStore.self) private var ideogram4Store
    @Environment(Ideogram4JobRunner.self) private var ideogram4Runner

    @Environment(\.openSettings) private var openSettings

    @State private var previewState: PreviewState = .idle
    @State private var selectedGalleryItem: GalleryItem?
    @State private var showingQueue: Bool = false
    @State private var showingNotepad: Bool = false
    @State private var showingOutputDirPrompt: Bool = false
    @State private var params = ParamsPanelState()
    @State private var ideogramParams = Ideogram4ParamsPanelState()
    @State private var fullSizeImage: NSImage?
    @State private var boxOverlay: BoxOverlayContext?

    @State private var showingParams: Bool = true
    @State private var pendingSelectPath: String?
    @State private var mfluxAutoInstall: MfluxAutoInstall = .idle

    @AppStorage("galleryPanelWidth") private var savedGalleryWidth: Double = 260
    @State private var galleryWidth: Double = 260
    @State private var galleryDragBase: Double?

    private var isAnyStoreRunning: Bool {
        store.isRunning || ideogram4Store.isRunning
    }

    private var paramsPane: some View {
        ParamsPanelView(params: params, ideogramParams: ideogramParams)
            .frame(width: 350)
            .frame(maxHeight: .infinity)
    }

    /// Routes the precision picker to the active family's quantize, persisting
    /// the Ideogram choice. Mirrors the binding ParamsPanelView used to own.
    private var unifiedQuantize: Binding<Int> {
        Binding(
            get: { params.model.isIdeogram4 ? ideogramParams.quantize : params.quantize },
            set: { v in
                if params.model.isIdeogram4 {
                    ideogramParams.quantize = v
                    settings.lastIdeogramQuantize = v
                } else {
                    params.quantize = v
                }
            }
        )
    }

    /// Model selector for the top header. Switching the model resets the
    /// dependent Flux defaults (steps/guidance/dims) just as before.
    private var headerModelPicker: some View {
        ModelPickerView(
            model: $params.model,
            customModelRepo: $params.customModelRepo,
            customBaseModel: $params.customBaseModel,
            quantize: unifiedQuantize
        )
        .onChange(of: params.model) { _, m in
            if m.isIdeogram4 {
                ideogramParams.loras = settings.defaultLoras.filter { $0.modelFamily == .ideogram4 }
                return
            }
            guard m != .custom else { return }
            let d = settings.resolvedDefaults(for: m)
            params.steps = d.steps
            params.guidance = d.guidance
            params.quantize = d.quantize
            params.lowRam = d.lowRam
            params.negativePrompt = d.negativePrompt
            params.width = d.width
            params.height = d.height
            params.loras = d.loras.isEmpty
                ? settings.defaultLoras.filter { $0.modelFamily == .flux }
                : d.loras
            params.isEditMode = false
            params.editImagePaths = []
        }
    }

    private var previewPaneView: some View {
        PreviewPaneView(
            state: previewState,
            onRemix: { meta in params.apply(metadata: meta, newSeed: true); generate() },
            onApplySettings: { meta in params.apply(metadata: meta, newSeed: false) },
            onRemixIdeogram: { meta in applyIdeogram(meta, newSeed: true); generate() },
            onApplyIdeogramSettings: { meta in applyIdeogram(meta, newSeed: false) },
            onUseInImg2Img: useInImg2Img,
            onCancel: { runner.cancel(); ideogram4Runner.cancel() },
            onClear: clearPreview,
            onEditBoxesOverImage: editBoxesOverImage,
            onShowFullSize: { img in withAnimation(.easeInOut(duration: 0.2)) { fullSizeImage = img } },
            hasPrev: galleryNavInfo.hasPrev,
            hasNext: galleryNavInfo.hasNext,
            onNavigatePrev: { navigateGallery(-1) },
            onNavigateNext: { navigateGallery(+1) }
        )
    }

    private var previewPane: some View {
        previewPaneView.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var galleryPaneView: some View {
        GenerationGalleryView(
            selectedItem: $selectedGalleryItem,
            modelFilter: params.modelFamily,
            onRemix: { meta in params.apply(metadata: meta, newSeed: true); generate() },
            onApplySettings: { meta in params.apply(metadata: meta, newSeed: false) },
            onRemixIdeogram: { meta in applyIdeogram(meta, newSeed: true); generate() },
            onApplyIdeogramSettings: { meta in applyIdeogram(meta, newSeed: false) },
            onUseInImg2Img: useInImg2Img,
            onSelectBoard: { name in params.board = name },
            onClearPreview: clearPreview,
            isFullSizeShowing: fullSizeImage != nil
        )
    }

    private var galleryPane: some View {
        galleryPaneView
            .frame(width: CGFloat(galleryWidth))
            .frame(maxHeight: .infinity)
    }

    var body: some View {
        mainContent
            .sheet(isPresented: $showingOutputDirPrompt) {
                OutputDirectoryPromptView(isPresented: $showingOutputDirPrompt)
                    .environment(settings)
            }
            .sheet(item: $boxOverlay) { ctx in
                boxOverlaySheet(ctx)
            }
            .onAppear {
                galleryWidth = savedGalleryWidth
                params.applyDefaults(from: settings)
                ideogramParams.applyDefaults(settings: settings)
                try? IdeogramPromptConfig.seedIfNeeded()
                if settings.outputDir.isEmpty {
                    showingOutputDirPrompt = true
                } else {
                    gallery.scan(outputDir: settings.outputDir)
                }
                Task { @MainActor in
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
            .task { await checkAndAutoInstallMflux() }
            .onChange(of: settings.defaultLoras) { _, updated in
                let notesByPath = Dictionary(uniqueKeysWithValues: updated.compactMap { e -> (String, String)? in
                    e.notes.isEmpty ? nil : (e.path, e.notes)
                })
                for i in params.loras.indices {
                    if let note = notesByPath[params.loras[i].path] {
                        params.loras[i].notes = note
                    }
                }
                let currentPaths = Set(params.loras.map(\.path))
                for entry in updated where !currentPaths.contains(entry.path) && entry.modelFamily == .flux {
                    params.loras.append(entry)
                }
                ideogramParams.loras = updated.filter { $0.modelFamily == .ideogram4 }
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
                guard count > 1 else { return } // first image handled by lastCompletedOutputPath
                gallery.scan(outputDir: settings.outputDir)
            }
            .onChange(of: ideogram4Runner.lastCompletedOutputPath) { _, path in
                pendingSelectPath = path
                gallery.scan(outputDir: settings.outputDir)
            }
            .onChange(of: ideogram4Runner.batchImageLanded) { _, count in
                guard count > 1 else { return }
                gallery.scan(outputDir: settings.outputDir)
            }
            .onChange(of: gallery.items) { _, newItems in
                guard let path = pendingSelectPath,
                      let item = newItems.first(where: { $0.path == path }) else { return }
                selectedGalleryItem = item
                pendingSelectPath = nil
            }
    }

    private var mainContent: some View {
        ZStack {
            HStack(spacing: 0) {
                if showingParams {
                    paramsPane

                    // Static separator — the params panel is a fixed width.
                    Divider()
                        .padding(.vertical, 3)
                }

                previewPane

                Divider()
                    .padding(.horizontal, 3)
                    .overlay {
                        // Transparent ~10pt grab zone centred on the 1pt divider.
                        // An overlay widens the resize target without padding the
                        // panes apart the way horizontal padding on the divider
                        // itself would (overlays don't affect HStack layout).
                        Color.clear
                            .frame(width: 10)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                    .onChanged { value in
                                        let base: Double
                                        if let b = galleryDragBase { base = b } else {
                                            galleryDragBase = galleryWidth; base = galleryWidth
                                        }
                                        galleryWidth = max(160, min(500, base - value.translation.width))
                                    }
                                    .onEnded { _ in
                                        galleryDragBase = nil
                                        savedGalleryWidth = galleryWidth
                                    }
                            )
                            .onHover { hovering in
                                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                    }

                galleryPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    topControlBar
                    mfluxInstallBanner
                }
            }

            if let img = fullSizeImage {
                FullSizeImageView(
                    image: img,
                    onDismiss: { withAnimation(.easeInOut(duration: 0.2)) { fullSizeImage = nil } },
                    hasPrev: galleryNavInfo.hasPrev,
                    hasNext: galleryNavInfo.hasNext,
                    onNavigatePrev: { navigateGallery(-1) },
                    onNavigateNext: { navigateGallery(+1) }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .toolbar { mainToolbar }
        .sheet(isPresented: $showingQueue) {
            queueSheet
        }
        .sheet(isPresented: $showingNotepad) {
            NotepadView()
                .environment(settings)
        }
        .onChange(of: runner.activeJob?.id) { _, id in
            guard let id, let job = store.jobs.first(where: { $0.id == id }) else { return }
            selectedGalleryItem = nil
            previewState = .activeJob(job)
        }
        .onChange(of: ideogram4Runner.activeJob?.id) { _, id in
            guard let id, let job = ideogram4Store.jobs.first(where: { $0.id == id }) else { return }
            selectedGalleryItem = nil
            previewState = .activeIdeogram4Job(job)
        }
        .onChange(of: selectedGalleryItem?.id) { _, id in
            guard let id, let item = gallery.items.first(where: { $0.id == id }) else {
                if selectedGalleryItem == nil { restoreActiveJobPreview() }
                return
            }
            previewState = .galleryItem(item)
            if fullSizeImage != nil {
                let url = item.url
                Task.detached(priority: .userInitiated) {
                    let img = NSImage(contentsOf: url)
                    await MainActor.run { if let img { self.fullSizeImage = img } }
                }
            }
        }
        .onChange(of: gallery.items.map(\.id)) { _, ids in
            // If the previewed item is deleted out from under us (e.g. shift+delete
            // the last image in a group), drop back to the idle/active-job state
            // instead of leaving the detail pane spinning on a missing file.
            guard case let .galleryItem(item) = previewState, !ids.contains(item.id) else { return }
            selectedGalleryItem = nil
            restoreActiveJobPreview()
        }
        .background {
            Button("") { showingQueue.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showingParams.toggle() } label: {
                Label("Toggle Params Panel", systemImage: "sidebar.leading")
            }
            .help("Toggle params panel")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { showingNotepad = true } label: {
                Label("Notepad", systemImage: "note.text")
            }
            .help("Open the notepad for reusable prompt notes")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { openSettings() } label: {
                Label("Settings", systemImage: "gear")
            }
        }
    }

    private var queueSheet: some View {
        NavigationStack {
            // Show the queue for the active model family. The two pipelines have
            // separate stores; previously this always showed the Flux queue, so
            // Ideogram jobs (single-shot and batch) never appeared.
            Group {
                if params.modelFamily == .ideogram4 {
                    Ideogram4QueueDrawerView(selectedJob: Binding(
                        get: {
                            if case let .activeIdeogram4Job(j) = previewState { return j }
                            return nil
                        },
                        set: { job in
                            if let j = job { previewState = .activeIdeogram4Job(j) }
                        }
                    ))
                    .environment(ideogram4Store)
                    .environment(ideogram4Runner)
                    .environment(settings)
                } else {
                    QueueDrawerView(selectedJob: Binding(
                        get: {
                            if case let .activeJob(j) = previewState { return j }
                            return nil
                        },
                        set: { job in
                            if let j = job { previewState = .activeJob(j) }
                        }
                    ))
                    .environment(store)
                    .environment(runner)
                    .environment(settings)
                }
            }
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
        // Generate group is window-centered; the model selector is pinned to the
        // leading edge in the same ZStack so its width doesn't shift the center.
        ZStack {
            HStack(spacing: 12) {
                let canGenerate: Bool = switch params.modelFamily {
                case .flux:
                    !params.prompt.trimmingCharacters(in: .whitespaces).isEmpty
                        && (!params.isEditMode || !params.editImagePaths.isEmpty)
                case .ideogram4:
                    ideogramParams.isReadyToGenerate(settings: settings)
                }
                HStack(spacing: 0) {
                    Button { generate() } label: {
                        Label("Generate  ⌘↵", systemImage: "wand.and.stars")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canGenerate)
                    // Batch button: auto-generates N random seeds into one warm job.
                    // Shown for whichever family has a random (-1) seed selected.
                    let seedIsRandom = params.modelFamily == .flux
                        ? params.seed == -1
                        : ideogramParams.seed == -1
                    if seedIsRandom {
                        Rectangle()
                            .fill(.white.opacity(0.35))
                            .frame(width: 1, height: 16)
                        BatchMenuButton(
                            counts: [3, 5, 10] + (settings.batchShortcutPreset == 0
                                ? [settings.batchShortcutCustomCount] : []),
                            shortcutCount: settings.batchShortcutCount,
                            isDisabled: !canGenerate
                        ) { count in generate(count: count) }
                            .frame(width: 28, height: 28)
                    }
                }
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
                .opacity(canGenerate ? 1.0 : 0.5)
                .focusEffectDisabled()
                .help("Generate (⌘↵)")

                // Batch shortcut (⌘⌥↵). A SwiftUI button — not a static NSEvent
                // monitor — so it always binds to the live, currently-active
                // ContentView's state. The old static monitor captured the first
                // window's `self`, so after switching the model family (or in a
                // second window) it submitted the stale family's last job.
                Button("") { generate(count: settings.batchShortcutCount) }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(!canGenerate)
                    .hidden()
                    .accessibilityHidden(true)

                Button { showingQueue.toggle() } label: {
                    queueStatusLabel
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(isAnyStoreRunning ? "Generating — click to view queue (⌘K)" : "Show queue (⌘K)")

                fixedSeedPill
            }

            HStack {
                headerModelPicker
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// Whether the active model family has a fixed (non-random) seed set.
    private var seedIsFixed: Bool {
        params.modelFamily == .flux ? params.seed != -1 : ideogramParams.seed != -1
    }

    /// Pill shown next to the queue counter when a fixed seed is set; its ✕
    /// clears the seed for both Flux and Ideogram back to random.
    @ViewBuilder
    private var fixedSeedPill: some View {
        if seedIsFixed {
            HStack(spacing: 4) {
                Image(systemName: "lock.fill").font(.caption2)
                Text("Fixed Seed").font(.caption)
                Button {
                    params.seed = -1
                    ideogramParams.seed = -1
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption2)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Clear the fixed seed (return to random)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(.secondary)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .help("A fixed seed is set — every generation reuses it.")
        }
    }

    private var queueStatusLabel: some View {
        ZStack {
            // Invisible anchor sized to the widest running state so the
            // button never shifts when text changes.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("99/99 images").monospacedDigit()
            }
            .hidden()

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
            } else if ideogram4Store.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if let job = ideogram4Runner.activeJob, job.seeds.count > 1 {
                        let done = job.completedSeedsInBatch
                        let total = job.seeds.count
                        Text("\(done)/\(total) images")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        let remaining = ideogram4Store.pendingJobs.count + 1
                        Text("\(remaining) left")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("Queue", systemImage: "list.bullet")
            }
        }
    }

    // MARK: - Gallery navigation

    private var galleryNavInfo: (hasPrev: Bool, hasNext: Bool) {
        guard let item = selectedGalleryItem else { return (false, false) }
        let items = gallery.items.filter { $0.board == item.board }
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return (false, false) }
        return (idx > 0, idx < items.count - 1)
    }

    @ViewBuilder
    private var mfluxInstallBanner: some View {
        switch mfluxAutoInstall {
        case .idle:
            EmptyView()
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing mflux…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("mflux ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        case let .failed(msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("mflux install failed — open Settings → Advanced to retry")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(msg)
                Spacer()
                Button("Retry") { Task { await checkAndAutoInstallMflux() } }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func useInImg2Img(_ path: String) {
        if params.isEditMode {
            if !params.editImagePaths.contains(path) { params.editImagePaths.append(path) }
        } else {
            params.imagePath = path
        }
    }

    /// Switches the params panel to the Ideogram 4 family and replays a completed
    /// generation's settings. Mirrors the Flux `params.apply(metadata:newSeed:)` path.
    private func applyIdeogram(_ meta: Ideogram4Metadata, newSeed: Bool) {
        params.model = .ideogram4
        ideogramParams.apply(metadata: meta, newSeed: newSeed)
    }

    /// Loads the image's bounding boxes (and dimensions) into the live Ideogram
    /// form and opens the box-overlay editor over the image. Prompt fields, seed,
    /// and preset are left untouched so the user can adjust boxes in isolation.
    private func editBoxesOverImage(_ meta: Ideogram4Metadata, image: NSImage) {
        params.model = .ideogram4
        ideogramParams.caption.compositionalDeconstruction.elements =
            meta.caption.compositionalDeconstruction.elements
        ideogramParams.width = meta.width
        ideogramParams.height = meta.height
        boxOverlay = BoxOverlayContext(image: image, width: meta.width, height: meta.height)
    }

    private func boxOverlaySheet(_ ctx: BoxOverlayContext) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Adjust Boxes")
                    .font(.headline)
                Spacer()
                Button("Done") { boxOverlay = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            BBoxEditorView(
                elements: $ideogramParams.caption.compositionalDeconstruction.elements,
                outputWidth: ctx.width,
                outputHeight: ctx.height,
                isExpanded: true,
                backgroundImage: ctx.image
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 940, height: 600)
    }

    private func clearPreview() {
        selectedGalleryItem = nil
        restoreActiveJobPreview()
    }

    private func restoreActiveJobPreview() {
        if let j = runner.activeJob {
            previewState = .activeJob(j)
        } else if let j = ideogram4Runner.activeJob {
            previewState = .activeIdeogram4Job(j)
        } else {
            previewState = .idle
        }
    }

    private func navigateGallery(_ delta: Int) {
        guard let current = selectedGalleryItem else { return }
        let items = gallery.items.filter { $0.board == current.board }
        guard !items.isEmpty else { return }
        if let idx = items.firstIndex(where: { $0.id == current.id }) {
            let next = max(0, min(items.count - 1, idx + delta))
            if next != idx { selectedGalleryItem = items[next] }
        }
    }

    private func checkAndAutoInstallMflux() async {
        guard BinaryDetector.mfluxGenerateFlux2(in: settings.mfluxBinaryDir).isEmpty else { return }
        mfluxAutoInstall = .installing
        do {
            let binDir = try await MfluxInstaller.install()
            settings.mfluxBinaryDir = binDir
            mfluxAutoInstall = .done
            try? await Task.sleep(for: .seconds(3))
            mfluxAutoInstall = .idle
        } catch {
            mfluxAutoInstall = .failed(error.localizedDescription)
        }
    }

    // MARK: - Generate

    private func generate(count: Int = 1) {
        NSApp.keyWindow?.makeFirstResponder(nil)

        switch params.modelFamily {
        case .flux:
            guard !params.prompt.trimmingCharacters(in: .whitespaces).isEmpty,
                  !params.isEditMode || !params.editImagePaths.isEmpty else { return }
            settings.lastPrompt = params.prompt
            settings.lastWidth = params.width
            settings.lastHeight = params.height
            settings.lastLoras = params.loras
            settings.lastModel = params.model
            settings.lastQuantize = params.quantize
            let job = params.makeJob(count: count, templates: settings.activeTemplates)
            store.add(job)
            if runner.activeJob == nil {
                selectedGalleryItem = nil
                previewState = .activeJob(job)
            }
            runner.runNext(in: store, settings: settings)

        case .ideogram4:
            guard ideogramParams.isReadyToGenerate(settings: settings) else { return }
            settings.lastModel = .ideogram4 // remember family across sessions
            settings.lastIdeogramPreset = ideogramParams.preset
            settings.lastIdeogramWidth = ideogramParams.width
            settings.lastIdeogramHeight = ideogramParams.height
            settings.lastIdeogramQuantize = ideogramParams.quantize
            settings.lastIdeogramCaption = ideogramParams.caption
            settings.lastIdeogramPlainPrompt = ideogramParams.plainPrompt
            settings.lastIdeogramUsePlainPrompt = ideogramParams.usePlainPrompt
            settings.lastIdeogramSeed = ideogramParams.seed
            // Low-RAM and strict-validation live in Settings → Models → Ideogram;
            // pull the current values so live edits apply to this run.
            ideogramParams.lowRam = settings.ideogram4LowRam
            ideogramParams.strictValidation = settings.ideogram4StrictValidation
            let job = ideogramParams.makeJob(count: count)
            ideogram4Store.add(job)
            ideogram4Runner.runNext(in: ideogram4Store, settings: settings)
        }
    }
}
