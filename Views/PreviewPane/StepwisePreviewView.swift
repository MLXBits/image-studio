import SwiftUI

struct StepwisePreviewView: View {
    let job: FluxJob
    let onCancel: () -> Void

    @State private var displayedImage: NSImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Image area
            ZStack {
                Color.black.opacity(0.05)

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

            // Progress bar + controls
            VStack(spacing: 8) {
                if job.totalSteps > 0 {
                    ProgressView(value: job.progressFraction)
                        .progressViewStyle(.linear)
                        .padding(.horizontal)
                }

                HStack(spacing: 12) {
                    progressLabel
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 16)
        }
        .onChange(of: job.latestStepwisePath) { _, path in
            loadStepwiseImage(path: path)
        }
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

    private var progressLabel: some View {
        HStack(spacing: 4) {
            if job.totalSteps > 0 {
                Text("Step \(job.currentStep)/\(job.totalSteps)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Starting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
