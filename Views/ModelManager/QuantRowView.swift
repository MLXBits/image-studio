import SwiftUI

/// One quant of a model in the detail pane: size, RAM fit, and download state with its actions.
struct QuantRowView: View {
    let model: FluxModelVariant
    let status: QuantStatus

    @Environment(AppSettings.self) private var settings
    @Environment(WeightDownloadStore.self) private var weightDownloads
    @State private var confirmingRemove = false

    private var run: WeightDownloadStore.Run? {
        weightDownloads.runs[.weights(model, quantize: status.quantize)]
    }

    private var isRunning: Bool {
        run?.phase == .running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(status.label).fontWeight(.medium)
                    .frame(width: 56, alignment: .leading)
                Text("≈\(Int(status.sizeGB.rounded())) GB download")
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                HStack(spacing: 5) {
                    Circle().fill(status.fit.color).frame(width: 8, height: 8)
                    Text("≈\(Int(status.ramGB.rounded())) GB RAM").foregroundStyle(.secondary)
                }
                .help(status.fit.tooltip)
                Spacer(minLength: 8)
                if !isRunning {
                    DownloadStateView(
                        phase: run?.phase, cached: status.cached, start: start,
                        cancel: cancel, remove: { confirmingRemove = true }, progress: EmptyView()
                    )
                }
            }
            if isRunning, let run {
                HStack(spacing: 12) {
                    DownloadRunningView(
                        cancel: cancel, progress: DownloadElapsedText(run: run, hubDir: settings.hfHubDir)
                    )
                }
            }
            if case let .failed(message)? = run?.phase, let run {
                DownloadFailureView(message: message, log: run.log)
            }
        }
        .alert("Delete cached weights?", isPresented: $confirmingRemove) {
            Button("Delete", role: .destructive) {
                guard run?.phase != .running else { return }
                Task { await weightDownloads.delete(model: model, quantize: status.quantize, settings: settings) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will permanently delete the \(status.label) weights for"
                    + " \(model.displayName) from disk. You can re-download them later."
            )
        }
    }

    private func cancel() {
        weightDownloads.cancel(.weights(model, quantize: status.quantize))
    }

    private func start() {
        weightDownloads.start(model: model, quantize: status.quantize, settings: settings)
    }
}
