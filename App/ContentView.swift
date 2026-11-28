// swiftlint:disable file_length
import AppKit
import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    /// Identifies a pending box-overlay editor session (image + its generation dims).
    private struct BoxOverlayContext: Identifiable {
        let id = UUID()
        let image: NSImage
        let width: Int
        let height: Int
    }

    /// One or more source images awaiting the SeedVR2 Upscale sheet. Holds more than
    /// one when the user upscales a gallery multi-selection; the sheet's chosen
    /// settings apply to every source.
    private struct UpscaleTarget: Identifiable {
        let id = UUID()
        let sources: [SeedVR2UpscaleSheet.Source]
    }

    /// Floor for the gallery pane once the window is too narrow to honour the user's width.
    private static let minGalleryWidth: CGFloat = 160
    /// Granularity of that clamp — see ``clampedGalleryWidth``.
    private static let galleryWidthStep: CGFloat = 16

    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var profiles
    @Environment(FamilyRegistry.self) private var families
    @Environment(GalleryStore.self) private var gallery
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(TimingStore.self) private var timing
    @Environment(MfluxDriverController.self) private var driverController
    @Environment(LoraLibraryStore.self) private var loraLibrary
    @Environment(UpdateChecker.self) private var updates
    @Environment(BackendModelStore.self) private var backendModels
    @Environment(ModelManagerRouter.self) private var router
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    @State private var previewState: PreviewState = .idle
    @State private var selectedGalleryItem: GalleryItem?
    @State private var showingQueue: Bool = false
    @State private var showingNotepad: Bool = false
    /// New / Rename / Remove, as picked from the toolbar's profile menu.
    @State private var profileAction: ProfileAction?
    @State private var showingOutputDirPrompt: Bool = false
    @AppStorage(ModelsFolderStepView.doneKey) private var modelsFolderStepDone = false
    /// The Models window opens once, when the first-run sheet closes.
    @AppStorage("firstRun.modelManagerShown") private var modelManagerShown = false
    /// Set when the user picks "Upscale…" on an image — presents the SeedVR2 sheet.
    @State private var upscaleTarget: UpscaleTarget?
    @State private var forms = FamilyForms()
    /// Model-picker handlers whose next reset to defaults must be skipped,
    /// because a programmatic change has just written the form itself. That
    /// change is either the launch-time restore of the last-used model or a
    /// gallery replay (Apply Settings / Remix). Each handler consumes its own
    /// entry once. See ``ModelChangeObserver``.
    @State private var suppressedModelObservers: Set<ModelChangeObserver> = []
    /// The precision a "Use this model" switch sets once the picker's reset to defaults has run.
    @State private var pendingUseQuantize: Int?
    @State private var fullSizeImage: NSImage?
    @State private var fullSizeLoadTask: Task<Void, Never>?
    /// Takes the window into real full-screen while `fullSizeImage` is up, so the
    /// viewer owns the whole screen and leaves no titlebar to drag.
    @State private var viewerFullScreen = ViewerFullScreenController()
    @State private var comparePair: ComparePair?
    @State private var boxOverlay: BoxOverlayContext?

    @State private var showingParams: Bool = true
    @State private var pendingSelectPath: String?

    @AppStorage("galleryPanelWidth") private var savedGalleryWidth: Double = 260
    @State private var galleryWidth: Double = 260
    @State private var galleryDragBase: Double?
    /// Live width of the three-pane row, used to keep the fixed-width params pane from
    /// being clipped when the window (or a wide gallery) over-constrains the layout.
    @State private var contentWidth: CGFloat = 0

    private var params: ParamsPanelState {
        forms.flux
    }

    private var ideogramParams: Ideogram4ParamsPanelState {
        forms.ideogram4
    }

    private var krea2Params: Krea2ParamsPanelState {
        forms.krea2
    }

    private var zimageParams: ZImageParamsPanelState {
        forms.zimage
    }

    private var qwen21Params: Qwen21ParamsPanelState {
        forms.qwen21
    }

    /// Every family's queue, for queueing, stopping and the hand-off.
    private var queues: FamilyQueues {
        FamilyQueues(
            all: families.all,
            settings: settings, coordinator: coordinator, timing: timing, driverController: driverController
        )
    }

    private var generateAction: GenerateAction {
        GenerateAction(settings: settings, forms: forms, queues: queues, families: families)
    }

    private var replayAction: ReplayAction {
        ReplayAction(forms: forms, suppressedModelObservers: $suppressedModelObservers)
    }

    /// What the menu bar acts on while this window is in front.
    private var mainWindowActions: MainWindowActions {
        MainWindowActions(
            sheetIsUp: showingQueue || showingNotepad || showingOutputDirPrompt || boxOverlay != nil
                || upscaleTarget != nil || profileAction != nil,
            canGenerate: canGenerate,
            isGenerating: queues.isAnyRunning,
            generate: { generate() },
            batchCount: settings.batchShortcutCount,
            generateBatch: { generate(count: settings.batchShortcutCount) },
            stop: { queues.stopAll() },
            showingParams: showingParams,
            toggleParams: { showingParams.toggle() },
            showingQueue: showingQueue,
            toggleQueue: { showingQueue.toggle() },
            showNotepad: { showingNotepad = true },
            showModels: { showModels() },
            image: selectedGalleryItem.map { imageActions(for: $0) }
        )
    }

    private var paramsPane: some View {
        ParamsPanelView(forms: forms) { prompts in
            // A scenario batch: one image job per rolled prompt, in the live family.
            generate(count: prompts.count, scenarioPrompts: prompts)
        }
        .frame(width: 350)
        .frame(maxHeight: .infinity)
    }

    /// Routes the precision picker to the active family's quantize, persisting
    /// the Ideogram choice. A custom checkpoint's is its target family's, which
    /// its jobs read.
    private var unifiedQuantize: Binding<Int> {
        Binding(
            get: { forms.active?.quantize ?? params.quantize },
            set: { v in
                forms.active?.quantize = v
                if params.modelFamily == .ideogram4 {
                    settings.lastIdeogramQuantize = v
                }
            }
        )
    }

    /// What the next job generates with, as the model button shows it and the warm driver compares.
    private var currentSelection: ModelSelection {
        .picked(
            params.model, quantize: unifiedQuantize.wrappedValue,
            customRepo: params.customModelRepo, customBase: params.customBaseModel
        )
    }

    /// The active model's source-image item for the gallery and preview menus, or
    /// nil when it has no source input. The active model decides, since
    /// ``useInImg2Img(_:as:)`` feeds its form whatever family the image came from.
    private var sourceImageAction: SourceImageAction? {
        SourceImageInput.forActive(currentSelection, fluxEditMode: params.isEditMode)
            .map { input in SourceImageAction(input: input) { path in useInImg2Img(path, as: input) } }
    }

    /// The model button in the top header. Switching the model resets the
    /// dependent Flux defaults (steps/guidance/dims) just as before.
    private var headerModelButton: some View {
        ModelButton(
            model: params.model,
            customRepo: params.customModelRepo,
            customBase: params.customBaseModel,
            quantize: unifiedQuantize.wrappedValue,
            routesToComfy: settings.runsOnComfy(currentSelection.variant),
            busy: coordinator.activeFamily != nil,
            onOpen: { showModels() },
            onUse: { applyUse($0) }
        )
        // Pattern 5: a committed change of model, precision or custom checkpoint proactively
        // evicts a warm model that no longer matches (debounced in the controller).
        .onChange(of: currentSelection.key, initial: true) { _, key in
            driverController.selectionChanged(to: key)
        }
        // The Models window's Custom entry starts its draft from the main window's checkpoint.
        .onChange(of: params.customModelRepo, initial: true) { _, repo in
            router.mainCustom.repo = repo
        }
        .onChange(of: params.customBaseModel, initial: true) { _, target in
            router.mainCustom.loadsAs = target
        }
        .onChange(of: params.model) { _, m in
            // "Use this model" picks a precision with the model. Apply it on the way out, after
            // the reset below (or the family form's early return) has set that family's default.
            defer {
                if let quantize = pendingUseQuantize {
                    unifiedQuantize.wrappedValue = quantize
                    pendingUseQuantize = nil
                }
            }
            // The launch-time restore and gallery replays write the form right
            // after moving the picker. Skip the defaults reset for that change so it
            // doesn't overwrite the restored or replayed LoRAs and settings.
            if suppressedModelObservers.remove(.model) != nil {
                return
            }
            resetForm(for: m)
        }
        // A custom checkpoint runs through whichever family it loads as, so
        // changing that target has to realign the same per-family form state a
        // direct model switch does.
        .onChange(of: params.customBaseModel) { _, target in
            guard params.model == .custom else { return }
            if suppressedModelObservers.remove(.customBase) != nil {
                return
            }
            _ = adoptFamilyForm(target)
            params.dropUnusableImg2ImgSource()
        }
    }

    private var previewPaneView: some View {
        PreviewPaneView(
            state: previewState,
            onReplay: { sidecar, mode in replay(sidecar, mode) },
            sourceImage: sourceImageAction,
            onCancel: { queues.stopAll() },
            onClear: clearPreview,
            onEditBoxesOverImage: editBoxesOverImage,
            onShowFullSize: { img in withAnimation(.easeInOut(duration: 0.2)) { fullSizeImage = img } },
            onSetGalleryFlag: { flag in updatePreviewItem { gallery.setFlag(flag, for: $0) } },
            onSetGalleryRating: { rating in updatePreviewItem { gallery.setRating(rating, for: $0) } },
            onUpscale: { path in promptUpscale(paths: [path]) },
            onRetry: { previewState.previewedJob.map { queues.restart($0) } },
            hasPrev: galleryNavInfo.hasPrev,
            hasNext: galleryNavInfo.hasNext,
            onNavigatePrev: { navigateGallery(-1) },
            onNavigateNext: { navigateGallery(+1) },
            escapeEnabled: previewEscapeEnabled
        )
    }

    /// Escape should clear the previewed gallery item only when no modal layer sits in
    /// front of it. While a sheet, the box editor, or the full-size overlay is up, those
    /// own the escape key.
    private var previewEscapeEnabled: Bool {
        fullSizeImage == nil && comparePair == nil && !showingQueue && !showingNotepad
            && !showingOutputDirPrompt && boxOverlay == nil
    }

    private var previewPane: some View {
        previewPaneView.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var galleryPaneView: some View {
        GenerationGalleryView(
            selectedItem: $selectedGalleryItem,
            modelFilter: params.modelFamily,
            onReplay: { sidecar, mode in replay(sidecar, mode) },
            sourceImage: sourceImageAction,
            onUpscale: { paths in promptUpscale(paths: paths) },
            onSelectBoard: setActiveBoard,
            onClearPreview: clearPreview,
            onCompare: { select, candidate in
                withAnimation(.easeInOut(duration: 0.2)) {
                    comparePair = ComparePair(selectId: select.id, candidateId: candidate.id)
                }
            },
            isFullSizeShowing: fullSizeImage != nil
        )
    }

    private var galleryPane: some View {
        galleryPaneView
            .frame(width: clampedGalleryWidth)
            .frame(maxHeight: .infinity)
    }

    /// The gallery's on-screen width, capped so the fixed-width params pane (350) and the
    /// preview's minimum (320) always stay visible. The user's preferred `galleryWidth` is
    /// still honored whenever the window is wide enough — it only yields when space is tight,
    /// so shrinking the window can never clip the params controls off the left edge.
    private var clampedGalleryWidth: CGFloat {
        let preferred = CGFloat(galleryWidth)
        guard contentWidth > 0 else { return preferred }
        let paramsSpace: CGFloat = showingParams ? 351 : 0 // params pane + its divider
        let reserved = paramsSpace + 320 + 8 // + preview minimum + gallery divider
        // Quantized while the clamp binds. Wide windows return `preferred`, a constant, so
        // dragging doesn't touch the gallery's width at all. Once the window is narrow
        // enough for this to bind, an unstepped value changes that width on every pixel of
        // the drag — and each change costs a full SwiftUI re-layout plus an NSCollectionView
        // grid reflow, which is what made the last stretch of a resize sluggish. Stepping
        // cuts those relayouts by the step size; the preview pane is flexible and absorbs
        // the remainder, so nothing is left blank.
        let available = max(Self.minGalleryWidth, contentWidth - reserved)
        let stepped = (available / Self.galleryWidthStep).rounded(.down) * Self.galleryWidthStep
        return min(preferred, max(Self.minGalleryWidth, stepped))
    }

    /// App Store first run: the models-folder step is still to come (spec §4).
    private var needsModelsStep: Bool {
        BuildFlavor.isAppStore && !modelsFolderStepDone
    }

    /// Split into two chains: SwiftUI's type-checker times out on a single modifier
    /// chain this long, so the queue/runner observers live in a second property.
    private var bodyBase: some View {
        mainContent
            // At most one family runs at a time (GenerationCoordinator), so one ID covers them all.
            .onChange(of: queues.activeJobID) { _, id in
                guard id != nil else { return }
                selectedGalleryItem = nil
                restoreActiveJobPreview()
            }
            // References change after launch too; keep them undeletable in the gallery.
            .onChange(of: forms.lockedSourcePaths) { _, paths in
                gallery.lockedPaths = paths
            }
            // The Models window's "Use this model", while this window is open.
            .onChange(of: router.pendingUse) { _, request in
                guard let request else { return }
                router.pendingUse = nil
                applyUse(request)
            }
            .sheet(
                isPresented: $showingOutputDirPrompt,
                onDismiss: {
                    guard !modelManagerShown else { return }
                    modelManagerShown = true
                    router.show(.model(.flux3Klein), open: openWindow)
                },
                content: {
                    OutputDirectoryPromptView(
                        isPresented: $showingOutputDirPrompt,
                        includeModelsStep: needsModelsStep,
                        startAtModelsStep: !settings.outputDir.isEmpty
                    )
                    .environment(settings)
                    .environment(profiles)
                }
            )
            .sheet(item: $boxOverlay) { ctx in
                boxOverlaySheet(ctx)
            }
            .onAppear {
                galleryWidth = savedGalleryWidth
                // Arm the suppression only when the restore will actually change
                // the model (and thus fire onChange). If lastModel already equals
                // the initial default, onChange won't fire and the flag must stay
                // down so the next genuine user switch isn't swallowed.
                let launchModel = params.model
                suppressedModelObservers = settings.lastModel != params.model ? [.model] : []
                for form in forms.all {
                    form.applyDefaults(settings: settings, library: loraLibrary)
                }
                try? IdeogramPromptConfig.seedIfNeeded()
                try? ScenarioPromptConfig.seedIfNeeded()
                try? ScenarioExamplePrompts.seedIfNeeded()
                if settings.outputDir.isEmpty || needsModelsStep {
                    showingOutputDirPrompt = true
                }
                #if DEBUG
                    // `-showFirstRunPrompt YES` replays the first-run sheet (it lands in the
                    // arguments domain of `UserDefaults.standard`).
                    if UserDefaults.standard.bool(forKey: "showFirstRunPrompt") {
                        showingOutputDirPrompt = true
                    }
                #endif
                // "Use this model" pressed while this window was closed.
                if let request = router.pendingUse {
                    router.pendingUse = nil
                    applyUseAtLaunch(request, launchModel: launchModel)
                }
                if !settings.outputDir.isEmpty {
                    gallery.scan(outputDir: settings.outputDir)
                }
                gallery.lockedPaths = forms.lockedSourcePaths
                Task { @MainActor in
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
            .onAppear { backendModels.attach(settings) }
            .onChange(of: settings.comfyURL) { _, _ in backendModels.restart() }
            .onChange(of: settings.comfyBackendEnabled) { _, _ in backendModels.restart() }
            .onChange(of: settings.openAIBaseURL) { _, _ in backendModels.restart() }
            .onChange(of: settings.llmBackend) { _, _ in backendModels.restart() }
            .task(id: queues.isAnyRunning) { backendModels.localRunInFlight = queues.isAnyRunning }
            .onChange(of: loraLibrary.allDefaultLoras) { old, updated in
                forms.followLibraryDefaults(from: old, to: updated)
            }
            // A profile switch tears this view down while the outgoing profile
            // is still active, so the unsaved form drafts are kept with it.
            .onDisappear { generateAction.saveContentDrafts() }
    }

    var body: some View {
        bodyBase
            // One handler for every family's landings: a new run selects its first
            // image, and landings that arrive together cost one gallery scan.
            .onChange(of: queues.landings) { old, new in
                let outcome = LandingDiff.compare(old: old, new: new)
                if let path = outcome.selectPath {
                    pendingSelectPath = path
                }
                if outcome.landed {
                    gallery.scheduleScan(outputDir: settings.outputDir)
                }
            }
            // Cross-family queue hand-off: when whichever family was running finishes its
            // own queue, start the next family's pending jobs. Only one runs at a time
            // (the GenerationCoordinator gate), so this is what keeps queued work draining.
            // One handler on the union: pump only starts work once every store is idle.
            .onChange(of: queues.isAnyRunning) { _, running in
                if !running {
                    queues.pump()
                }
            }
            .onChange(of: gallery.items) { _, newItems in
                guard let path = pendingSelectPath,
                      let item = newItems.first(where: { $0.path == path }) else { return }
                selectedGalleryItem = item
                pendingSelectPath = nil
            }
            .errorAlert("Could not save the queue", message: queueSaveError)
    }

    /// The first family whose queue history failed to save. Dismissing the alert
    /// clears it; the next save that fails shows it again.
    private var queueSaveError: Binding<String?> {
        let failed = queues.histories.first { $0.saveError != nil }
        return Binding(get: { failed?.saveError }, set: { failed?.saveError = $0 })
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
                                        if let b = galleryDragBase {
                                            base = b
                                        } else {
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
                                if hovering {
                                    NSCursor.resizeLeftRight.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                    }

                galleryPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    topControlBar
                    ToolchainBanner()
                    MissingLibraryBanner()
                    SupportNudgeBanner()
                }
            }

            if let img = fullSizeImage {
                FullSizeImageView(
                    image: img,
                    onDismiss: {
                        fullSizeLoadTask?.cancel()
                        fullSizeLoadTask = nil
                        withAnimation(.easeInOut(duration: 0.2)) { fullSizeImage = nil }
                    },
                    hasPrev: galleryNavInfo.hasPrev,
                    hasNext: galleryNavInfo.hasNext,
                    onNavigatePrev: { navigateGallery(-1) },
                    onNavigateNext: { navigateGallery(+1) },
                    flag: fullSizeCullItem?.flag,
                    rating: fullSizeCullItem?.rating ?? 0,
                    onFlag: fullSizeCullItem == nil ? nil : { flag in cullFullSize(flag: flag) },
                    onRating: fullSizeCullItem == nil ? nil : { rating in cullFullSize(rating: rating) }
                )
                .transition(.opacity)
                .zIndex(1)
            }

            if let select = compareSelectItem, let candidate = compareCandidateItem {
                let siblings = GalleryCull.siblings(of: select, in: gallery.items, family: params.modelFamily)
                CompareView(
                    selectItem: select,
                    candidateItem: candidate,
                    candidatePosition: (siblings.firstIndex { $0.id == candidate.id }.map { $0 + 1 }) ?? 1,
                    candidateCount: siblings.count,
                    onDismiss: { withAnimation(.easeInOut(duration: 0.2)) { comparePair = nil } },
                    onCycleCandidate: { delta in cycleCompareCandidate(delta) },
                    onSwap: { comparePair = comparePair?.swapped },
                    onFlagCandidate: { flag in compareFlagCandidate(flag) },
                    onRateCandidate: { rating in compareRateCandidate(rating) }
                )
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .toolbar { mainToolbar }
        // The viewer is the whole screen while it's up: no toolbar to slide down
        // on a mouse-to-top, and no window chrome over the image.
        .toolbar(fullSizeImage == nil ? .automatic : .hidden, for: .windowToolbar)
        .background { WindowAccessor { viewerFullScreen.attach(to: $0) } }
        .onChange(of: fullSizeImage != nil) { _, showing in
            viewerFullScreen.setActive(showing)
        }
        .sheet(isPresented: $showingQueue) {
            queueSheet
        }
        .sheet(isPresented: $showingNotepad) {
            NotepadView()
                .environment(settings)
        }
        .modifier(ProfileActionPresenter(action: $profileAction))
        .sheet(item: $upscaleTarget) { target in
            SeedVR2UpscaleSheet(
                sources: target.sources,
                settings: settings,
                onConfirm: { jobs in
                    upscaleTarget = nil
                    startUpscale(jobs)
                },
                onCancel: { upscaleTarget = nil }
            )
        }
        .onChange(of: selectedGalleryItem?.id) { _, id in
            guard let id, let item = gallery.items.first(where: { $0.id == id }) else {
                if selectedGalleryItem == nil {
                    restoreActiveJobPreview()
                }
                return
            }
            previewState = .galleryItem(item)
            fullSizeLoadTask?.cancel()
            fullSizeLoadTask = nil
            if fullSizeImage != nil {
                let url = item.url
                fullSizeLoadTask = Task {
                    let img = await Task.detached(priority: .userInitiated) {
                        NSImage(contentsOf: url)
                    }.value
                    guard !Task.isCancelled, selectedGalleryItem?.id == item.id, let img else { return }
                    fullSizeImage = img
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
        .focusedSceneValue(\.mainWindow, mainWindowActions)
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showingParams.toggle() } label: {
                Label("Toggle Params Panel", systemImage: "sidebar.leading")
            }
            .help("Toggle params panel (\(KeyboardShortcutCatalog.toggleParams.symbols))")
        }

        // Debug builds carry the in-repo MARKETING_VERSION, which trails the
        // latest tag, so the badge would always show. Release builds get the tag
        // version injected by CI, so this only nags when genuinely behind.
        #if !DEBUG
            if updates.isUpdateAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let url = updates.releaseURL {
                            openURL(url)
                        }
                    } label: {
                        Label("Update available", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .help("A new release (\(updates.latestVersion ?? "")) is available — click to view it on GitHub")
                }
            }
        #endif

        ToolbarItem(placement: .primaryAction) {
            Button { showingNotepad = true } label: {
                Label("Notepad", systemImage: "note.text")
            }
            .help("Open the notepad for reusable prompt notes (\(KeyboardShortcutCatalog.showNotepad.symbols))")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { openWindow(id: SupportView.windowID) } label: {
                Label("Support", systemImage: "heart")
                    .foregroundStyle(Color.accentColor)
            }
            .help("Support MLXBits Image Studio")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { openSettings() } label: {
                Label("Settings", systemImage: "gear")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            ProfileMenu(
                onAction: { profileAction = $0 },
                onShowQueue: { showingQueue = true }
            )
        }
    }

    /// Whether the queue sheet should show the SeedVR2 upscale queue. True while an
    /// upscale is running or when the preview is showing an upscale job — the two
    /// moments a user opens the queue expecting to find their upscale. Since SeedVR2
    /// is never the picker-selected `modelFamily`, this is the only way its jobs
    /// surface in the drawer.
    private var showSeedVR2Queue: Bool {
        if families.seedVR2.isRunning {
            return true
        }
        if case .activeSeedVR2Job = previewState {
            return true
        }
        return false
    }

    private var queueSheet: some View {
        NavigationStack {
            // Show the queue for the active model family. The two pipelines have
            // separate stores; previously this always showed the Flux queue, so
            // Ideogram jobs (single-shot and batch) never appeared.
            Group {
                if showSeedVR2Queue {
                    // SeedVR2 isn't a picker-selected family, so key off the running
                    // upscale / previewed upscale instead of `params.modelFamily`;
                    // otherwise upscale jobs never appear in the queue drawer.
                    FamilyQueueDrawerView(
                        families.seedVR2, selectedJobWithoutDuplicate: previewSelection(SeedVR2RunnerSpec.self)
                    )
                } else {
                    switch params.modelFamily {
                    case .ideogram4:
                        FamilyQueueDrawerView(families.ideogram4, selectedJob: previewSelection(Ideogram4RunnerSpec.self))
                    case .krea2:
                        FamilyQueueDrawerView(families.krea2, selectedJob: previewSelection(Krea2RunnerSpec.self))
                    case .qwen21:
                        FamilyQueueDrawerView(families.qwen21, selectedJob: previewSelection(Qwen21RunnerSpec.self))
                    case .zimage:
                        FamilyQueueDrawerView(families.zimage, selectedJob: previewSelection(ZImageRunnerSpec.self))
                    case .flux, .seedvr2:
                        // SeedVR2 is never the picker family; it is handled above.
                        FamilyQueueDrawerView(families.flux, selectedJob: previewSelection(FluxRunnerSpec.self))
                    }
                }
            }
            .environment(settings)
            .environment(coordinator)
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

    private var canGenerate: Bool {
        forms.active?.canGenerate ?? false
    }

    private var topControlBar: some View {
        // Generate group is window-centered; the model selector is pinned to the
        // leading edge in the same ZStack so its width doesn't shift the center.
        ZStack {
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    Button { generate() } label: {
                        Label("Generate  \(KeyboardShortcutCatalog.generate.symbols)", systemImage: "wand.and.stars")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGenerate)
                    // Batch button: auto-generates N random seeds into one warm job.
                    // Shown for whichever family has a random (-1) seed selected.
                    if forms.active?.seed == -1 {
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
                .help("Generate (\(KeyboardShortcutCatalog.generate.symbols))")

                Button { showingQueue.toggle() } label: {
                    // Width is content-driven (icon, or a progress + count readout), so
                    // only the height is pinned to the standard target.
                    queueStatusLabel
                        .frame(minWidth: IconButtonMetrics.size, minHeight: IconButtonMetrics.size)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(queues.isAnyRunning
                    ? "Generating — click to view queue (\(KeyboardShortcutCatalog.toggleQueue.symbols))"
                    : "Show queue (\(KeyboardShortcutCatalog.toggleQueue.symbols))")

                fixedSeedPill
            }

            HStack(spacing: 6) {
                headerModelButton
                Spacer(minLength: 0)
                ResidencyPills(runsOnComfy: settings.runsOnComfy(currentSelection.variant))
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
        forms.active.map { $0.seed != -1 } ?? false
    }

    /// Pill shown next to the queue counter when a fixed seed is set; its ✕
    /// sets every family's seed back to random.
    @ViewBuilder
    private var fixedSeedPill: some View {
        if seedIsFixed {
            HStack(spacing: 4) {
                Image(systemName: "lock.fill").font(.caption2)
                Text("Fixed Seed").font(.caption)
                Button {
                    forms.clearFixedSeeds()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption2)
                }
                // Compact so the target stays inside the pill.
                .buttonStyle(.iconButtonCompact)
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

            // An upscale is single-output (no batch), so it shows the count of
            // upscales still queued behind the running one.
            if let running = queues.runningQueue {
                queueProgress(running.activeJob, pending: running.pendingCount)
            } else {
                Label("Queue", systemImage: "list.bullet")
            }
        }
    }

    // MARK: - Gallery navigation

    /// The gallery item currently shown in the full-size overlay, if the overlay was
    /// opened from a gallery image (rather than a live/completed job preview). Read
    /// from the store so its flag/rating are always current.
    private var fullSizeCullItem: GalleryItem? {
        guard let id = selectedGalleryItem?.id else { return nil }
        return gallery.items.first { $0.id == id }
    }

    /// The Compare overlay's two images, resolved fresh from the store so their
    /// flag/rating badges stay current. Both are nil when Compare isn't active.
    private var compareSelectItem: GalleryItem? {
        guard let id = comparePair?.selectId else { return nil }
        return gallery.items.first { $0.id == id }
    }

    private var compareCandidateItem: GalleryItem? {
        guard let id = comparePair?.candidateId else { return nil }
        return gallery.items.first { $0.id == id }
    }

    private var galleryNavInfo: (hasPrev: Bool, hasNext: Bool) {
        guard let item = selectedGalleryItem else { return (false, false) }
        return GalleryCull.edges(of: item, in: gallery.items, family: params.modelFamily)
    }

    /// "3/10 images" while a batch job runs, else how many jobs are left including the running one.
    private func queueProgress(_ job: (any GeneratedJob)?, pending: Int) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Group {
                if let job, job.seeds.count > 1 {
                    Text("\(job.completedSeedsInBatch)/\(job.seeds.count) images")
                } else {
                    Text("\(pending + 1) left")
                }
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    /// A queue drawer's selection: the previewed job when it belongs to that
    /// drawer's family. Choosing a row previews it.
    private func previewSelection<Spec: JobRunnerSpec>(_: Spec.Type) -> Binding<Spec.Job?> {
        Binding(
            get: { previewState.previewedJob as? Spec.Job },
            set: { job in
                if let job {
                    previewState = Spec.preview(job)
                }
            }
        )
    }

    /// Routes an image to the active family's source-image input: the img2img
    /// image (FLUX.2, Krea 2, Z-Image) or the edit-reference list (Flux edit mode,
    /// FLUX 3, Qwen-Image 2.1). `input` is what ``sourceImageAction`` chose, so a
    /// model with no such input never gets here. A reference turns Edit mode on, as
    /// it does for Qwen. Paths go through `settings.adoptSourceImage(_:)` like the
    /// panels' own drop handlers.
    private func useInImg2Img(_ path: String, as input: SourceImageInput) {
        switch params.modelFamily {
        case .flux:
            if input == .editReference {
                params.isEditMode = true
                EditImageListView.appendAdopted(
                    [path], to: &params.editImagePaths, maxCount: nil, adopt: settings.adoptSourceImage
                )
            } else {
                params.adoptImg2ImgSource(path, settings: settings)
            }
        case .krea2:
            krea2Params.adoptImg2ImgSource(path, settings: settings)
        case .zimage:
            zimageParams.adoptImg2ImgSource(path, settings: settings)
        case .qwen21:
            // Qwen has no img2img: the image becomes the next edit reference.
            qwen21Params.isEditMode = true
            EditImageListView.appendAdopted(
                [path], to: &qwen21Params.editImagePaths, maxCount: Qwen21Job.maxReferences,
                adopt: settings.adoptSourceImage
            )
        case .ideogram4, .seedvr2:
            break
        }
    }

    /// Puts a new group's name on the active family's board.
    private func setActiveBoard(_ name: String) {
        forms.active?.board = name
    }

    /// Aligns the non-Flux params form to `m` — Ideogram/Krea 2/Z-Image LoRAs and,
    /// for Z-Image, the Turbo-vs-base variant. Returns true when `m` belongs to one
    /// of those families and the caller should stop; false for Flux and `custom`.
    private func adoptFamilyForm(_ m: FluxModelVariant) -> Bool {
        if m.isIdeogram4 {
            ideogramParams.loras = loraLibrary.defaultLoras(for: .ideogram4)
            return true
        }
        if m.isKrea2 {
            // Restore the last-used Krea 2 LoRAs (mirrors `applyDefaults`), falling
            // back to defaults only when none were saved. Wiping straight to
            // defaults here dropped the remembered stack the moment the user
            // re-selected Krea 2 in the picker.
            let saved = settings.lastKrea2?.loras ?? []
            krea2Params.loras = saved.isEmpty
                ? loraLibrary.defaultLoras(for: .krea2)
                : saved
            return true
        }
        if m.isZImage {
            // Realign the shared Z-Image form to the picked variant (Turbo vs base)
            // — swaps step/guidance defaults only when untouched — and restore the
            // last-used LoRAs, falling back to defaults when none were saved.
            zimageParams.adoptVariant(m, settings: settings)
            let saved = settings.lastZImage?.loras ?? []
            zimageParams.loras = saved.isEmpty
                ? loraLibrary.defaultLoras(for: .zimage)
                : saved
            return true
        }
        if m.isQwen21 {
            let saved = settings.lastQwen21?.loras ?? []
            qwen21Params.loras = saved.isEmpty ? loraLibrary.defaultLoras(for: .qwen21) : saved
            return true
        }
        return false
    }

    /// What a switch of the model picker to `m` resets: the family form for a non-Flux
    /// model, else `m`'s Flux defaults. A custom checkpoint keeps the form as it is.
    private func resetForm(for m: FluxModelVariant) {
        if adoptFamilyForm(m) {
            return
        }
        guard m != .custom else {
            // A custom checkpoint keeps the form, but not an image its target can't use.
            params.dropUnusableImg2ImgSource()
            return
        }
        let d = settings.resolvedDefaults(for: m)
        params.steps = d.steps
        params.guidance = d.guidance
        params.quantize = d.quantize
        params.lowRam = d.lowRam
        params.negativePrompt = d.negativePrompt
        params.width = d.width
        params.height = d.height
        params.loras = loraLibrary.defaultLoras(for: .flux)
        params.isEditMode = false
        params.editImagePaths = []
        params.dropUnusableImg2ImgSource()
    }

    /// Applies "Use this model" as a pick from the picker menu. A model switch sets the
    /// precision in the `params.model` handler, after its reset; `onChange` runs on the next
    /// update, so setting it here would be overwritten.
    private func applyUse(_ request: ModelManagerRouter.UseRequest) {
        let busy = coordinator.activeFamily != nil
        switch ModelManagerRouter.outcome(of: request, currentModel: params.model, busy: busy) {
        case .ignore:
            break
        case .setQuantize:
            unifiedQuantize.wrappedValue = request.quantize
        case .setCustom:
            if let custom = request.custom {
                params.customModelRepo = custom.repo
                params.customBaseModel = custom.loadsAs
            }
        case .switchModel:
            if let custom = request.custom {
                switchToCustom(custom)
            } else {
                pendingUseQuantize = request.quantize
                params.model = request.model
            }
        }
    }

    /// Picks a custom checkpoint. The `params.model` handler resets nothing for `.custom`, and
    /// the `customBaseModel` handler runs only when the target changes, so the target's family
    /// form is adopted here (adopting it again from the handler changes nothing).
    private func switchToCustom(_ custom: ModelManagerRouter.CustomCheckpoint) {
        params.customModelRepo = custom.repo
        params.customBaseModel = custom.loadsAs
        params.model = .custom
        _ = adoptFamilyForm(custom.loadsAs)
        params.dropUnusableImg2ImgSource()
    }

    /// Opens the Models window at the main window's model.
    private func showModels() {
        router.show(ModelManagerRouter.item(for: params.model), open: openWindow)
    }

    /// Applies a "Use this model" request on top of the launch restore, when the request
    /// opened this window. The `params.model` handler compares against `launchModel`, so it
    /// may not fire at all: reset the form here, and arm it to skip its reset if it does fire.
    private func applyUseAtLaunch(_ request: ModelManagerRouter.UseRequest, launchModel: FluxModelVariant) {
        let busy = coordinator.activeFamily != nil
        switch ModelManagerRouter.outcome(of: request, currentModel: params.model, busy: busy) {
        case .ignore:
            return
        case .setQuantize:
            break
        case .setCustom, .switchModel:
            if let custom = request.custom {
                // The handlers fire on the next update; this applies the switch itself.
                suppressedModelObservers = launchModel != .custom ? [.model] : []
                switchToCustom(custom)
                return
            }
            suppressedModelObservers = launchModel != request.model ? [.model] : []
            params.model = request.model
            resetForm(for: request.model)
        }
        unifiedQuantize.wrappedValue = request.quantize
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
                elements: Bindable(ideogramParams).caption.compositionalDeconstruction.elements,
                outputWidth: ctx.width,
                outputHeight: ctx.height,
                isExpanded: true,
                backgroundImage: ctx.image,
                cameraStyle: Bindable(ideogramParams).caption.styleDescription
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
        previewState = queues.activePreview
    }

    // MARK: - SeedVR2 upscale

    /// Opens the Upscale sheet for `paths`, resolving each image's board from its
    /// gallery folder. Multiple paths (a gallery multi-selection) share one setup.
    private func promptUpscale(paths: [String]) {
        let sources = paths.map { SeedVR2UpscaleSheet.Source(path: $0, board: boardForPath($0)) }
        guard !sources.isEmpty else { return }
        upscaleTarget = UpscaleTarget(sources: sources)
    }

    /// Enqueues one or more upscale jobs and starts the runner (gate-serialized against
    /// the generative families), flipping the preview to the first active upscale when
    /// idle. Batch jobs queue behind it and run one at a time.
    private func startUpscale(_ jobs: [SeedVR2Job]) {
        guard !jobs.isEmpty else { return }
        if !queues.isAnyRunning {
            // Free any warm generative model before the upscale spawns its own process
            // (holding both risks OOM). When not idle, the hand-off ejects it.
            driverController.eject(reason: "model_switch")
        }
        if queues.enqueue(jobs, on: families.seedVR2), let first = jobs.first {
            selectedGalleryItem = nil
            previewState = SeedVR2RunnerSpec.preview(first)
        }
    }

    /// Derives the board (gallery subfolder) an image lives in from its path, so the
    /// upscaled result lands next to its source. Matches `buildOutputPath`'s
    /// `outputDir/board` layout; anything deeper or outside falls back to "Default".
    private func boardForPath(_ path: String) -> String {
        let outDir = URL(fileURLWithPath: settings.outputDir).standardizedFileURL.path
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
        if parent.path == outDir {
            return "Default"
        }
        if parent.deletingLastPathComponent().path == outDir {
            return parent.lastPathComponent
        }
        return "Default"
    }

    private func navigateGallery(_ delta: Int) {
        guard let current = selectedGalleryItem,
              let next = GalleryCull.step(from: current, by: delta, in: gallery.items, family: params.modelFamily) else { return }
        selectedGalleryItem = next
    }

    // MARK: - Full-size culling

    private func cullFullSize(flag: PickFlag?) {
        guard let item = fullSizeCullItem else { return }
        gallery.setFlag(GalleryCull.toggled(item.flag, pressing: flag), for: item)
        refreshSelectedGalleryItem()
    }

    private func cullFullSize(rating: Int) {
        guard let item = fullSizeCullItem else { return }
        gallery.setRating(rating, for: item)
        refreshSelectedGalleryItem()
    }

    /// Re-reads the selected item from the store so views bound to the snapshot pick up
    /// the new flag/rating. Keeps the same id, so it does not trigger an image reload.
    private func refreshSelectedGalleryItem() {
        guard let id = selectedGalleryItem?.id else { return }
        selectedGalleryItem = gallery.items.first { $0.id == id }
    }

    /// Detail-pane cull actions. The detail view already resolves the toggle, so `change`
    /// sets the value directly; then both the selection snapshot and the preview state
    /// are refreshed (same id, so no image reload) so the badge/stars update in place.
    private func updatePreviewItem(_ change: (GalleryItem) -> Void) {
        guard let id = selectedGalleryItem?.id,
              let item = gallery.items.first(where: { $0.id == id }) else { return }
        change(item)
        if let fresh = gallery.items.first(where: { $0.id == id }) {
            selectedGalleryItem = fresh
            previewState = .galleryItem(fresh)
        }
    }

    // MARK: - Compare

    private func cycleCompareCandidate(_ delta: Int) {
        guard let pair = comparePair,
              let select = gallery.items.first(where: { $0.id == pair.selectId }),
              let next = pair.cyclingCandidate(
                  by: delta, through: GalleryCull.siblings(of: select, in: gallery.items, family: params.modelFamily)
              ) else { return }
        comparePair = next
    }

    private func compareFlagCandidate(_ flag: PickFlag?) {
        guard let id = comparePair?.candidateId,
              let item = gallery.items.first(where: { $0.id == id }) else { return }
        gallery.setFlag(GalleryCull.toggled(item.flag, pressing: flag), for: item)
    }

    private func compareRateCandidate(_ rating: Int) {
        guard let id = comparePair?.candidateId,
              let item = gallery.items.first(where: { $0.id == id }) else { return }
        gallery.setRating(rating, for: item)
    }

    // MARK: - Generate

    /// Remix or Apply Settings. Remix also presses Generate, with the new seed.
    private func replay(_ sidecar: AnySidecar, _ mode: ReplayMode) {
        if replayAction(sidecar, mode: mode), mode == .remix {
            generate()
        }
    }

    /// One Generate press. The preview follows the first new job when nothing else was running.
    private func generate(count: Int = 1, scenarioPrompts: [String]? = nil) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let preview = generateAction(count: count, scenarioPrompts: scenarioPrompts) {
            selectedGalleryItem = nil
            previewState = preview
        }
    }

    // MARK: - Menu commands

    private func imageActions(for item: GalleryItem) -> MainWindowActions.ImageActions {
        let prompt = ImageMetadataInfo(galleryItem: item).prompt
        let upscale = { promptUpscale(paths: [item.path]) }
        return MainWindowActions.ImageActions(
            revealInFinder: { NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "") },
            copyPrompt: prompt.isEmpty ? nil : { PathCopy.copy(prompt) },
            applySettings: applySettingsAction(for: item),
            upscale: upscale
        )
    }

    /// Apply Settings for the image, as the gallery's context menu does.
    private func applySettingsAction(for item: GalleryItem) -> (() -> Void)? {
        item.replaySidecar.map { sidecar in { replay(sidecar, .applySettings) } }
    }
}
