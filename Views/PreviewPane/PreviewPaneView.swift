import SwiftUI

enum PreviewState {
    case idle
    case activeJob(FluxJob)
    case activeIdeogram4Job(Ideogram4Job)
    case galleryItem(GalleryItem)
}

struct PreviewPaneView: View {
    @Environment(FluxJobRunner.self) private var runner
    @Environment(\.openSettings) private var openSettings

    let state: PreviewState
    let onRemix: (GenerationMetadata) -> Void
    let onApplySettings: (GenerationMetadata) -> Void
    let onRemixIdeogram: (Ideogram4Metadata) -> Void
    let onApplyIdeogramSettings: (Ideogram4Metadata) -> Void
    let onUseInImg2Img: (String) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void
    var onEditBoxesOverImage: ((Ideogram4Metadata, NSImage) -> Void)?
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

                case let .activeJob(job):
                    switch job.status {
                    case .running:
                        StepwisePreviewView(job: job, onCancel: onCancel)

                    case .completed:
                        CompletedImageView(
                            job: job,
                            onApplySettings: onApplySettings,
                            onRemix: onRemix,
                            onUseInImg2Img: onUseInImg2Img,
                            onShowFullSize: onShowFullSize
                        )

                    case let .failed(msg):
                        failedView(message: msg, job: job)

                    case .cancelled:
                        cancelledView

                    case .pending:
                        pendingView(job: job)
                    }

                case let .activeIdeogram4Job(job):
                    switch job.status {
                    case .running:
                        Ideogram4StepwisePreviewView(job: job, onCancel: onCancel)

                    case .completed:
                        Ideogram4CompletedPreviewView(
                            job: job,
                            onRemix: onRemixIdeogram,
                            onApplySettings: onApplyIdeogramSettings
                        )

                    case let .failed(msg):
                        ideogram4FailedView(message: msg, job: job)

                    case .cancelled:
                        cancelledView

                    case .pending:
                        ideogram4PendingView(job: job)
                    }

                case let .galleryItem(item):
                    GalleryItemDetailView(
                        item: item,
                        onRemix: onRemix,
                        onApplySettings: onApplySettings,
                        onRemixIdeogram: onRemixIdeogram,
                        onApplyIdeogramSettings: onApplyIdeogramSettings,
                        onUseInImg2Img: onUseInImg2Img,
                        onEditBoxesOverImage: onEditBoxesOverImage,
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

        case let .activeJob(job):
            if case .running = job.status { return false }
            return true

        case let .activeIdeogram4Job(job):
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

    private func ideogram4FailedView(message: String, job: Ideogram4Job) -> some View {
        let combined = message + "\n" + job.log
        let isGatedRepo = combined.contains("private or gated repo")
            || combined.contains("GatedRepoError")
            || combined.contains("is restricted")
            || combined.contains("403 Client Error")
            || combined.contains("401 Client Error")

        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Generation failed")
                    .font(.headline)
                Spacer()
                if isGatedRepo, let url = FluxModelVariant.ideogram4.hfRepoURL(quantize: 0) {
                    Link("Accept Terms", destination: url)
                        .font(.caption)
                }
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

    private func ideogram4PendingView(job: Ideogram4Job) -> some View {
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
