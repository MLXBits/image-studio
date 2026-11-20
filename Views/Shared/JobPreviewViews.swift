import SwiftUI

/// Live stepwise preview for a running job of any family.
struct JobStepwisePreviewView<Job: GeneratedJob>: View {
    let job: Job
    let onCancel: () -> Void
    /// Shown until the first stepwise frame lands.
    var placeholder = "Generating…"

    @Environment(AppSettings.self) private var settings
    @State private var displayedImage: NSImage?
    @State private var showLog: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if showLog {
                logView
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if let img = displayedImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                    } else {
                        generatingPlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding()
            }

            VStack(spacing: 8) {
                if !showLog {
                    Group {
                        if job.isDenoising, job.totalSteps > 0 {
                            ProgressView(value: Double(job.currentStep) / Double(job.totalSteps))
                        } else {
                            ProgressView()
                        }
                    }
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                }

                HStack(spacing: 8) {
                    progressLabel
                    Spacer()
                    Button(showLog ? "Hide Log" : "View Log") { showLog.toggle() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.red)
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 16)
        }
        .onAppear { loadStepwiseImage(path: job.latestStepwisePath) }
        .onChange(of: job.latestStepwisePath) { _, path in loadStepwiseImage(path: path) }
    }

    private var logView: some View {
        LogTextView(
            text: job.log.isEmpty ? "No output yet." : job.log,
            fontSize: settings.logFontSize
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var generatingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.5)
            Text(placeholder)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var progressLabel: some View {
        if job.isDenoising {
            VStack(alignment: .leading, spacing: 1) {
                // Mirror tqdm exactly: currentStep is the completed-step count the CLI shows.
                Text("Step \(job.currentStep)/\(job.totalSteps)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let timing = job.stepTiming {
                    Text(timing)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Text(job.statusLine.isEmpty ? "Loading model…" : job.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func loadStepwiseImage(path: String?) {
        guard let path else {
            displayedImage = nil
            return
        }
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOfFile: path)
            await MainActor.run {
                guard path == job.latestStepwisePath else { return }
                displayedImage = img
            }
        }
    }
}

/// Completed-image preview for a job of any family: the image, its metadata
/// panel, and whichever actions the family supports. (In practice the preview
/// flips to the gallery item on completion; this is the queue-reselect path.)
struct JobCompletedPreviewView<Job: GeneratedJob, Meta>: View {
    let job: Job
    /// The job's metadata for replay (nil when it has none), and its
    /// metadata-panel contents.
    let metadataOf: (Job) -> Meta?
    let infoOf: (Job) -> ImageMetadataInfo
    var onRemix: ((Meta) -> Void)?
    var onApplySettings: ((Meta) -> Void)?
    var onUseInImg2Img: ((String) -> Void)?
    var onShowFullSize: ((NSImage) -> Void)?
    var onUpscale: ((String) -> Void)?
    var logTitle = "Generation Log"

    @State private var image: NSImage?
    @State private var showingLog: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.05)
                if let img = image {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding()
            .onTapGesture(count: 2) {
                if let image {
                    onShowFullSize?(image)
                }
            }
            .contextMenu { contextMenu }

            ImageMetadataPanel(
                info: infoOf(job),
                onApplySettings: replay(onApplySettings),
                onRemix: replay(onRemix),
                onUseInImg2Img: withOutput(onUseInImg2Img),
                onRevealInFinder: withOutput { path in
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                },
                onShowLog: job.log.isEmpty ? nil : { showingLog = true },
                onUpscale: withOutput(onUpscale)
            )
        }
        .onAppear { loadImage() }
        .onChange(of: job.outputPath) { _, _ in loadImage() }
        .sheet(isPresented: $showingLog) { logSheet }
    }

    @ViewBuilder private var contextMenu: some View {
        if let path = job.outputPath {
            Button("Copy Image") {
                guard let img = NSImage(contentsOfFile: path) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
            }
            Divider()
        }
        if let apply = replay(onApplySettings) {
            Button("Apply Settings", action: apply)
        }
        if let remix = replay(onRemix) {
            Button("Remix (new seed)", action: remix)
        }
        if let path = job.outputPath {
            if let onUseInImg2Img {
                Button("Use as Img2Img Input") { onUseInImg2Img(path) }
            }
            if let onUpscale {
                Button("Upscale…") { onUpscale(path) }
            }
            Divider()
            CopyPathMenu(path: path)
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            }
        }
        if !job.log.isEmpty {
            Button("Show Log") { showingLog = true }
        }
    }

    private var logSheet: some View {
        NavigationStack {
            LogTextView(text: job.log, fontSize: NSFont.smallSystemFontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(logTitle)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingLog = false }
                    }
                }
        }
        .frame(width: 640, height: 480)
    }

    /// `action` bound to this job's metadata, when it has both.
    private func replay(_ action: ((Meta) -> Void)?) -> (() -> Void)? {
        guard let action, let meta = metadataOf(job) else { return nil }
        return { action(meta) }
    }

    /// `action` bound to this job's output image, when it has both.
    private func withOutput(_ action: ((String) -> Void)?) -> (() -> Void)? {
        guard let action, let path = job.outputPath else { return nil }
        return { action(path) }
    }

    private func loadImage() {
        guard let path = job.outputPath else { return }
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOfFile: path)
            await MainActor.run { image = img }
        }
    }
}
