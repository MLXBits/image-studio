import AppKit
import SwiftUI

struct StepwisePreviewView: View {
    let job: FluxJob
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
                            let inProgress = min(job.currentStep + 1, job.totalSteps)
                            ProgressView(value: Double(inProgress) / Double(job.totalSteps))
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
                    Button(showLog ? "Hide Log" : "View Log") {
                        showLog.toggle()
                    }
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
        .onAppear {
            // Returning from the gallery remounts this view with empty @State; load the
            // most recent stepwise frame (already on disk) immediately instead of waiting
            // for the next step to fire onChange.
            loadStepwiseImage(path: job.latestStepwisePath)
        }
        .onChange(of: job.latestStepwisePath) { _, path in
            loadStepwiseImage(path: path)
        }
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
            ProgressView()
                .scaleEffect(1.5)
            Text("Generating…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var progressLabel: some View {
        if job.isDenoising {
            VStack(alignment: .leading, spacing: 1) {
                // currentStep = completed steps; display the in-progress step as currentStep+1,
                // capped at totalSteps (when all done, stays at N/N before decode clears isDenoising)
                let inProgress = min(job.currentStep + 1, job.totalSteps)
                Text("Step \(inProgress)/\(job.totalSteps)")
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
                // Detached loads can resolve out of order; ignore a stale frame that
                // finished after a newer one was already requested.
                guard path == job.latestStepwisePath else { return }
                displayedImage = img
            }
        }
    }
}

struct Ideogram4StepwisePreviewView: View {
    let job: Ideogram4Job
    let onCancel: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var displayedImage: NSImage?
    @State private var showLog: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if showLog {
                LogTextView(
                    text: job.log.isEmpty ? "No output yet." : job.log,
                    fontSize: settings.logFontSize
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if let img = displayedImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView().scaleEffect(1.5)
                            Text("Generating…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
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
                            let inProgress = min(job.currentStep + 1, job.totalSteps)
                            ProgressView(value: Double(inProgress) / Double(job.totalSteps))
                        } else {
                            ProgressView()
                        }
                    }
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                }
                HStack(spacing: 8) {
                    if job.isDenoising {
                        VStack(alignment: .leading, spacing: 1) {
                            let inProgress = min(job.currentStep + 1, job.totalSteps)
                            Text("Step \(inProgress)/\(job.totalSteps)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            if let timing = job.stepTiming {
                                Text(timing)
                                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        Text(job.statusLine.isEmpty ? "Loading model…" : job.statusLine)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(showLog ? "Hide Log" : "View Log") { showLog.toggle() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(.red)
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 16)
        }
        .onAppear {
            // Remounting after a gallery detour clears @State; show the latest captured
            // frame right away rather than waiting for the next step.
            loadStepwiseImage(path: job.latestStepwisePath)
        }
        .onChange(of: job.latestStepwisePath) { _, path in
            loadStepwiseImage(path: path)
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
                // Detached loads can resolve out of order; ignore a stale frame that
                // finished after a newer one was already requested.
                guard path == job.latestStepwisePath else { return }
                displayedImage = img
            }
        }
    }
}

struct Ideogram4CompletedPreviewView: View {
    let job: Ideogram4Job
    let onRemix: (Ideogram4Metadata) -> Void
    let onApplySettings: (Ideogram4Metadata) -> Void

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
                }
                Button("Apply Settings") { onApplySettings(metadata) }
                Button("Remix (new seed)") { onRemix(metadata) }
                if let path = job.outputPath {
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }
            }

            ImageMetadataPanel(
                info: ImageMetadataInfo(ideogram4Job: job),
                onApplySettings: { onApplySettings(metadata) },
                onRemix: { onRemix(metadata) },
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

    private var metadata: Ideogram4Metadata {
        Ideogram4Metadata.from(job: job)
    }

    private var logSheet: some View {
        NavigationStack {
            ScrollView {
                Text(job.log)
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
        guard let path = job.outputPath else { return }
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOfFile: path)
            await MainActor.run { image = img }
        }
    }
}
