import AppKit
import SwiftUI

// NSTextView-backed log viewer. SwiftUI Text + textSelection re-lays the full document on
// every append, causing beachballs on long generations. NSTextView only re-lays new content.
private struct LogTextView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        // swiftlint:disable:next force_cast
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textView.string = text
            textView.scrollToEndOfDocument(nil)
        }
    }
}

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
            await MainActor.run { displayedImage = img }
        }
    }
}
