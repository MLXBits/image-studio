import SwiftUI

/// Live progress preview for a running SeedVR2 upscale. Modeled on
/// ``Krea2StepwisePreviewView`` (the codebase keeps one per model family), bound
/// to ``SeedVR2Job``. SeedVR2 often runs in a single step, so the bar spends most
/// of its time indeterminate during model load + the decode.
struct SeedVR2StepwisePreviewView: View {
    let job: SeedVR2Job
    let onCancel: () -> Void

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
                            .aspectRatio(contentMode: .fit)
                    } else {
                        upscalingPlaceholder
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

    private var upscalingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.5)
            Text("Upscaling…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var progressLabel: some View {
        if job.isDenoising {
            VStack(alignment: .leading, spacing: 1) {
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

/// Completed-image preview for a SeedVR2 upscale — the upscaled result plus
/// reveal/log affordances. In practice the preview flips to the gallery item on
/// completion; this is the queue-reselect path.
struct SeedVR2CompletedPreviewView: View {
    let job: SeedVR2Job

    @State private var image: NSImage?
    @State private var showingLog: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.05)
                if let img = image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding()
            .contextMenu {
                if let path = job.outputPath {
                    Button("Copy Image") {
                        guard let img = NSImage(contentsOfFile: path) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([img])
                    }
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }
            }

            ImageMetadataPanel(
                info: ImageMetadataInfo(seedVR2Job: job),
                onApplySettings: nil,
                onRemix: nil,
                onUseInImg2Img: nil,
                onRevealInFinder: job.outputPath.map { path in {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                },
                onShowLog: job.log.isEmpty ? nil : { showingLog = true }
            )
        }
        .onAppear { loadImage() }
        .onChange(of: job.outputPath) { _, _ in loadImage() }
        .sheet(isPresented: $showingLog) { logSheet }
    }

    private var logSheet: some View {
        NavigationStack {
            LogTextView(text: job.log, fontSize: NSFont.smallSystemFontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Upscale Log")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingLog = false }
                    }
                }
        }
        .frame(width: 640, height: 480)
    }

    private func loadImage() {
        guard let path = job.outputPath else { return }
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOfFile: path)
            await MainActor.run { image = img }
        }
    }
}
