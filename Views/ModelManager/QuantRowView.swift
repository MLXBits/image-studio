import SwiftUI

/// One quant of a model in the detail pane: size, RAM fit, and download state with its actions.
struct QuantRowView: View {
    let model: FluxModelVariant
    let status: QuantStatus

    @Environment(AppSettings.self) private var settings
    @Environment(WeightDownloadStore.self) private var weightDownloads
    @Environment(ModelManagerRouter.self) private var router
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
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
                // Same pills as the model picker: disk turns green once cached, RAM takes the fit colour.
                EstimatePill(
                    text: "≈\(Int(status.sizeGB.rounded())) GB \(status.cached ? "cached" : "download")",
                    systemImage: status.cached ? "internaldrive" : "arrow.down.circle",
                    color: status.cached ? .green : .secondary
                )
                .frame(width: 140, alignment: .leading)
                EstimatePill(text: "≈\(Int(status.ramGB.rounded())) GB RAM", systemImage: "memorychip", color: status.fit.color)
                    .help(status.fit.tooltip)
                Spacer(minLength: 8)
                if !isRunning {
                    DownloadStateView(
                        phase: run?.phase, cached: status.cached, start: start,
                        cancel: cancel, remove: { confirmingRemove = true }, progress: EmptyView()
                    )
                    useButton
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
        .cachedRowHighlight(status.cached && !isRunning)
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

    /// Picks this model at this precision in the main window, as the model picker would.
    private var useButton: some View {
        let busy = coordinator.activeFamily != nil
        return Button("Use") {
            router.pendingUse = .init(model: model, quantize: status.quantize)
            openWindow(id: MLXBitsImageStudioApp.mainWindowID)
        }
        .modelManagerButton()
        .disabled(busy)
        .help(busy ? "Finish or stop the running job first" : "Use \(model.displayName) at \(status.label) in the main window")
    }

    private func cancel() {
        weightDownloads.cancel(.weights(model, quantize: status.quantize))
    }

    private func start() {
        weightDownloads.start(model: model, quantize: status.quantize, settings: settings)
    }
}
