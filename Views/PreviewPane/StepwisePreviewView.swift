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
                            .animation(.easeInOut(duration: 0.2), value: displayedImage)
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
                        if job.currentStep > 0 {
                            ProgressView(value: job.progressFraction)
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
                        .buttonStyle(.bordered)
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
        ScrollViewReader { proxy in
            ScrollView {
                Text(job.log.isEmpty ? "No output yet." : job.log)
                    .font(.system(size: settings.logFontSize, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("logBottom")
            }
            .onChange(of: job.log) { _, _ in proxy.scrollTo("logBottom") }
            .onAppear { proxy.scrollTo("logBottom") }
        }
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
        if job.currentStep > 0 {
            Text("Step \(job.currentStep)/\(job.totalSteps)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
