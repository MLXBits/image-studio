import SwiftUI

enum PreviewState {
    case idle
    case activeJob(FluxJob)
    case galleryItem(GalleryItem)
}

struct PreviewPaneView: View {
    @Environment(FluxJobRunner.self) private var runner
    @Environment(\.openSettings) private var openSettings

    let state: PreviewState
    let onRemix: (GenerationMetadata) -> Void
    let onApplySettings: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void
    var onShowFullSize: ((NSImage) -> Void)?
    var hasPrev: Bool = false
    var hasNext: Bool = false
    var onNavigatePrev: (() -> Void)?
    var onNavigateNext: (() -> Void)?

    var body: some View {
        ZStack {
            ZStack(alignment: .topTrailing) {
                switch state {
                case .idle:
                    idleView

                case .activeJob(let job):
                    switch job.status {
                    case .running:
                        StepwisePreviewView(job: job, onCancel: onCancel)

                    case .completed:
                        CompletedImageView(
                            job: job,
                            onRemix: onRemix,
                            onApplySettings: onApplySettings,
                            onUseInImg2Img: onUseInImg2Img,
                            onShowFullSize: onShowFullSize
                        )

                    case .failed(let msg):
                        failedView(message: msg, job: job)

                    case .cancelled:
                        cancelledView

                    case .pending:
                        pendingView(job: job)
                    }

                case .galleryItem(let item):
                    GalleryItemDetailView(
                        item: item,
                        onRemix: onRemix,
                        onApplySettings: onApplySettings,
                        onUseInImg2Img: onUseInImg2Img,
                        onShowFullSize: onShowFullSize
                    )
                }

                if showsClearButton {
                    Button { onClear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
            }

            // Navigation arrows — always visible, shown when prev/next exist
            if hasPrev || hasNext {
                HStack(spacing: 0) {
                    if hasPrev {
                        Button { onNavigatePrev?() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .background(.secondary.opacity(0.1), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 14)
                    }
                    Spacer()
                    if hasNext {
                        Button { onNavigateNext?() } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .background(.secondary.opacity(0.1), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 14)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var showsClearButton: Bool {
        switch state {
        case .idle: return false

        case .activeJob(let job):
            if case .running = job.status { return false }
            return true

        case .galleryItem: return true
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Ready to generate")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Write a prompt and press ⌘↵")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private func failedView(message: String, job: FluxJob) -> some View {
        let combined = message + "\n" + job.log
        let isGatedRepo = combined.contains("private or gated repo")
            || combined.contains("GatedRepoError")
            || combined.contains("is restricted")
            || combined.contains("403 Client Error")
            || combined.contains("401 Client Error")
        let repoURL: URL? = job.model != .custom
            ? job.model.hfRepoURL(quantize: job.quantize)
            : nil

        if isGatedRepo {
            return AnyView(VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                Text("Generation failed")
                    .font(.title3)
                VStack(spacing: 10) {
                    Text("This model is gated on HuggingFace.\nAccept the terms and add an access token to continue.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if let url = repoURL {
                        Link(destination: url) {
                            Label("Accept Terms on HuggingFace", systemImage: "arrow.up.right.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                    }

                    Button {
                        openSettings()
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .openSettingsAdvancedTab, object: nil)
                        }
                    } label: {
                        Label("Add HF Token in Settings", systemImage: "key")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                }
                .padding(.top, 4)
            }
            .padding())
        }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Generation failed")
                    .font(.headline)
                Spacer()
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(job.log.isEmpty ? message : job.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    Color.clear.frame(height: 1).id("errEnd")
                }
                .onAppear { proxy.scrollTo("errEnd") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }

    private var cancelledView: some View {
        VStack(spacing: 12) {
            Image(systemName: "stop.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Cancelled")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func pendingView(job: FluxJob) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Waiting in queue")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(job.displayName)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Full-size image overlay (shown in-place, no sheet window)

struct FullSizeImageView: View {
    let image: NSImage
    let onDismiss: () -> Void
    var hasPrev: Bool = false
    var hasNext: Bool = false
    var onNavigatePrev: (() -> Void)?
    var onNavigateNext: (() -> Void)?

    @State private var keyMonitor: Any?
    @State private var chromeVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                .onTapGesture(count: 2) { onDismiss() }

            // Close button — top-right, fades with chrome
            VStack {
                HStack {
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
                Spacer()
            }
            .opacity(chromeVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.5), value: chromeVisible)

            // Navigation arrows — vertically centered, fade with chrome
            if hasPrev || hasNext {
                HStack(spacing: 0) {
                    if hasPrev {
                        Button {
                            showChrome()
                            onNavigatePrev?()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.18), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 20)
                    }
                    Spacer()
                    if hasNext {
                        Button {
                            showChrome()
                            onNavigateNext?()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.18), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 20)
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(chromeVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: chromeVisible)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { showChrome() }
        }
        .onAppear {
            installKeyMonitor()
            scheduleHide()
        }
        .onDisappear {
            removeKeyMonitor()
            hideTask?.cancel()
        }
    }

    private func showChrome() {
        chromeVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2.5))
                chromeVisible = false
            } catch {
                // Cancelled — leave chrome visible
            }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }  // Escape
            onDismiss()
            return nil  // consume — prevents system from exiting tiled/zoomed window state
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

// MARK: - Gallery item detail (in center pane)

private struct GalleryItemDetailView: View {
    let item: GalleryItem
    let onRemix: (GenerationMetadata) -> Void
    let onApplySettings: (GenerationMetadata) -> Void
    let onUseInImg2Img: (String) -> Void
    var onShowFullSize: ((NSImage) -> Void)?

    @State private var image: NSImage?
    @State private var showingLog: Bool = false

    var body: some View {
        let info = ImageMetadataInfo(item: item) ?? ImageMetadataInfo(path: item.path)
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.05)
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding()
            .onTapGesture(count: 2) {
                if let img = image { onShowFullSize?(img) }
            }
            .contextMenu {
                Button("Copy Image") {
                    guard let img = NSImage(contentsOfFile: item.path) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                }
                if let meta = item.metadata {
                    Divider()
                    Button("Apply Settings") {
                        var corrected = meta
                        corrected.board = item.board == "Default" ? nil : item.board
                        onApplySettings(corrected)
                    }
                    Button("Remix (new seed)") { onRemix(meta) }
                    Button("Use as Img2Img Input") { onUseInImg2Img(item.path) }
                }
                if info.log != nil {
                    Divider()
                    Button("Show Log") { showingLog = true }
                }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                }
            }

            ImageMetadataPanel(
                info: info,
                onApplySettings: item.metadata.map { meta in {
                    var corrected = meta
                    corrected.board = item.board == "Default" ? nil : item.board
                    onApplySettings(corrected)
                }
                }, onRemix: item.metadata.map { meta in { onRemix(meta) } },
                onUseInImg2Img: { onUseInImg2Img(item.path) },
                onRevealInFinder: {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                },
                onShowLog: info.log != nil ? { showingLog = true } : nil
            )
        }
        .onAppear { loadImage() }
        .onChange(of: item.id) { _, _ in loadImage() }
        .sheet(isPresented: $showingLog) { logSheet(log: info.log ?? "") }
    }

    private func logSheet(log: String) -> some View {
        NavigationStack {
            ScrollView {
                Text(log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Generation Log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingLog = false }
                }
            }
        }
        .frame(width: 640, height: 480)
    }

    private func loadImage() {
        image = nil
        let url = item.url
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { image = img }
        }
    }
}
