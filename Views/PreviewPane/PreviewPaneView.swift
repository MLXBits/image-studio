import AppKit
import SwiftUI

enum PreviewState {
    case idle
    case activeJob(FluxJob)
    case activeIdeogram4Job(Ideogram4Job)
    case activeKrea2Job(Krea2Job)
    case activeZImageJob(ZImageJob)
    case activeQwen21Job(Qwen21Job)
    case activeSeedVR2Job(SeedVR2Job)
    case galleryItem(GalleryItem)

    /// The queue job the preview shows, of whichever family. Nil when idle or
    /// showing a gallery item.
    var previewedJob: (any GeneratedJob)? {
        switch self {
        case let .activeJob(job): job
        case let .activeIdeogram4Job(job): job
        case let .activeKrea2Job(job): job
        case let .activeZImageJob(job): job
        case let .activeQwen21Job(job): job
        case let .activeSeedVR2Job(job): job
        case .idle, .galleryItem: nil
        }
    }
}

struct PreviewPaneView: View {
    @Environment(FluxJobRunner.self) private var runner
    @Environment(\.openSettings) private var openSettings

    let state: PreviewState
    /// Remix or Apply Settings, for an image of any family.
    let onReplay: (AnySidecar, ReplayMode) -> Void
    let onUseInImg2Img: (String) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void
    var onEditBoxesOverImage: ((Ideogram4Metadata, NSImage) -> Void)?
    var onShowFullSize: ((NSImage) -> Void)?
    var onSetGalleryFlag: ((PickFlag?) -> Void)?
    var onSetGalleryRating: ((Int) -> Void)?
    var onUpscale: ((String) -> Void)?
    /// Puts the failed job the preview shows back at the front of its queue.
    var onRetry: (() -> Void)?
    var hasPrev: Bool = false
    var hasNext: Bool = false
    var onNavigatePrev: (() -> Void)?
    var onNavigateNext: (() -> Void)?
    /// When true, Escape clears the previewed item even if the gallery grid doesn't hold
    /// first responder. Disabled while a modal layer (sheet / full-size overlay) is in front.
    var escapeEnabled: Bool = false

    @State private var escapeMonitor: Any?
    @State private var hostWindow = WindowRef()

    /// Escape should dismiss the preview whenever the ✕ would: any non-running active job
    /// or a selected gallery item. (The running state has no ✕ and is dismissed via Cancel.)
    private var escapeActive: Bool {
        escapeEnabled && showsClearButton
    }

    var body: some View {
        ZStack {
            ZStack(alignment: .topTrailing) {
                switch state {
                case .idle:
                    idleView

                case let .activeJob(job):
                    jobPreview(job) {
                        completedPreview(
                            job,
                            sidecarOf: { job in
                                job.outputPath
                                    .flatMap { MetadataSidecar.read(GenerationMetadata.self, for: $0) }
                                    .map(AnySidecar.flux)
                            },
                            infoOf: { ImageMetadataInfo(job: $0) }
                        )
                    } failed: { message in
                        failedView(message: message, job: job)
                    }

                case let .activeIdeogram4Job(job):
                    jobPreview(job) {
                        // Ideogram 4 has no img2img.
                        completedPreview(
                            job,
                            sidecarOf: { .ideogram4(Ideogram4Metadata.from(job: $0)) },
                            infoOf: { ImageMetadataInfo(ideogram4Job: $0) },
                            takesImg2Img: false
                        )
                    } failed: { message in
                        FailedJobView(
                            message: message, log: job.log,
                            repoURL: FluxModelVariant.ideogram4.hfRepoURL(quantize: job.quantize),
                            onRetry: onRetry
                        ) { onReplay(.ideogram4(Ideogram4Metadata.from(job: job)), .applySettings) }
                    }

                case let .activeKrea2Job(job):
                    jobPreview(job) {
                        completedPreview(
                            job,
                            sidecarOf: { .krea2(Krea2Metadata.from(job: $0)) },
                            infoOf: { ImageMetadataInfo(krea2Job: $0) }
                        )
                    } failed: { message in
                        FailedJobView(message: message, log: job.log, onRetry: onRetry) {
                            onReplay(.krea2(Krea2Metadata.from(job: job)), .applySettings)
                        }
                    }

                case let .activeQwen21Job(job):
                    jobPreview(job) {
                        completedPreview(
                            job,
                            sidecarOf: { .qwen21(Qwen21Metadata.from(job: $0)) },
                            infoOf: { ImageMetadataInfo(qwen21Job: $0) }
                        )
                    } failed: { message in
                        FailedJobView(message: message, log: job.log, onRetry: onRetry) {
                            onReplay(.qwen21(Qwen21Metadata.from(job: job)), .applySettings)
                        }
                    }

                case let .activeZImageJob(job):
                    jobPreview(job) {
                        completedPreview(
                            job,
                            sidecarOf: { .zimage(ZImageMetadata.from(job: $0)) },
                            infoOf: { ImageMetadataInfo(zimageJob: $0) }
                        )
                    } failed: { message in
                        FailedJobView(
                            message: message, log: job.log,
                            repoURL: job.modelVariant.hfRepoURL(quantize: job.quantize),
                            onRetry: onRetry
                        ) { onReplay(.zimage(ZImageMetadata.from(job: job)), .applySettings) }
                    }

                case let .activeSeedVR2Job(job):
                    jobPreview(job, placeholder: "Upscaling…") {
                        // No Remix or Apply Settings here, unlike the upscale's gallery item:
                        // the preview moves to that item when the job completes.
                        JobCompletedPreviewView(
                            job: job,
                            sidecarOf: { _ in nil },
                            infoOf: { ImageMetadataInfo(seedVR2Job: $0) },
                            onShowFullSize: onShowFullSize,
                            onUpscale: onUpscale,
                            logTitle: "Upscale Log"
                        )
                    } failed: { message in
                        FailedJobView(title: "Upscale failed", message: message, log: job.log, onRetry: onRetry)
                    }

                case let .galleryItem(item):
                    GalleryItemDetailView(
                        item: item,
                        onReplay: onReplay,
                        onUseInImg2Img: onUseInImg2Img,
                        onEditBoxesOverImage: onEditBoxesOverImage,
                        onShowFullSize: onShowFullSize,
                        onSetFlag: onSetGalleryFlag,
                        onSetRating: onSetGalleryRating,
                        onUpscale: onUpscale
                    )
                }

                if showsClearButton {
                    Button { onClear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.iconButton)
                    .accessibilityLabel("Close preview")
                    // Insets the button from the corner — the hit area is the style's
                    // 28pt frame, not this padding.
                    .padding(6)
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
                                .frame(width: IconButtonMetrics.size, height: IconButtonMetrics.size)
                                .background(.secondary.opacity(0.1), in: Circle())
                        }
                        .buttonStyle(.iconButton)
                        .accessibilityLabel("Previous image")
                        .padding(.leading, 14)
                    }
                    Spacer()
                    if hasNext {
                        Button { onNavigateNext?() } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: IconButtonMetrics.size, height: IconButtonMetrics.size)
                                .background(.secondary.opacity(0.1), in: Circle())
                        }
                        .buttonStyle(.iconButton)
                        .accessibilityLabel("Next image")
                        .padding(.trailing, 14)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background { WindowAccessor { hostWindow.window = $0 } }
        .onAppear {
            if escapeActive {
                installEscapeMonitor()
            }
        }
        .onDisappear { removeEscapeMonitor() }
        .onChange(of: escapeActive) { _, active in
            if active {
                installEscapeMonitor()
            } else {
                removeEscapeMonitor()
            }
        }
    }

    /// Every state but idle and a running job has a ✕ (a running job has Cancel).
    private var showsClearButton: Bool {
        if case .idle = state {
            return false
        }
        return state.previewedJob?.status != .running
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Ready to generate")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Write a prompt and press \(KeyboardShortcutCatalog.generate.symbols)")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
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

    private func failedView(message: String, job: FluxJob) -> some View {
        let isGatedRepo = FailureSummary.isGatedRepo(message: message, log: job.log)
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

                    if let onRetry {
                        Button(action: onRetry) {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
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
        return AnyView(FailedJobView(message: message, log: job.log, onRetry: onRetry) {
            onReplay(.flux(GenerationMetadata.from(job: job)), .applySettings)
        })
    }

    private func queuedView(displayName: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Waiting in queue")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(displayName)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// One queue job's preview by status, the same for every family; the
    /// family supplies its completed and failed views.
    @ViewBuilder
    private func jobPreview(
        _ job: some QueueListedJob,
        placeholder: String = "Generating…",
        @ViewBuilder completed: () -> some View,
        @ViewBuilder failed: (String) -> some View
    ) -> some View {
        switch job.status {
        case .running: JobStepwisePreviewView(job: job, onCancel: onCancel, placeholder: placeholder)
        case .completed: completed()
        case let .failed(message): failed(message)
        case .cancelled: cancelledView
        case .pending: queuedView(displayName: job.displayName)
        }
    }

    /// A generated image's completed preview, with the pane's full-size,
    /// upscale and (unless the family has none) img2img actions.
    private func completedPreview<Job: GeneratedJob>(
        _ job: Job,
        sidecarOf: @escaping (Job) -> AnySidecar?,
        infoOf: @escaping (Job) -> ImageMetadataInfo,
        takesImg2Img: Bool = true
    ) -> some View {
        JobCompletedPreviewView(
            job: job,
            sidecarOf: sidecarOf,
            infoOf: infoOf,
            onReplay: onReplay,
            onUseInImg2Img: takesImg2Img ? onUseInImg2Img : nil,
            onShowFullSize: onShowFullSize,
            onUpscale: onUpscale
        )
    }

    // MARK: - Escape monitor

    /// A local key monitor makes Escape clear the preview regardless of which view holds
    /// first responder — the gallery grid often loses focus (after generation resets the
    /// responder, or after clicking into the detail pane), so its own keyDown handler can't
    /// be relied on alone. Skips text editing and panel windows so it never steals Escape
    /// from an in-progress edit or a system panel (e.g. the color picker).
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        let host = hostWindow
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape, in this window only.
            guard event.keyCode == 53, host.owns(event) else { return event }
            if NSApp.keyWindow is NSPanel {
                return event
            }
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSText {
                return event // mid-edit — let the field cancel instead
            }
            onClear()
            return nil // consume so AppKit doesn't also exit zoomed/tiled window state
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}
