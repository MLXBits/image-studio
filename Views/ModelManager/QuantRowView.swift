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
                statusView
            }
            if case let .failed(message)? = run?.phase, let run {
                Text(message).font(.caption).foregroundStyle(.red)
                DisclosureGroup("Log") { logView(run) }.font(.caption)
            }
        }
        .alert("Delete cached weights?", isPresented: $confirmingRemove) {
            Button("Delete", role: .destructive) {
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

    @ViewBuilder private var statusView: some View {
        switch run?.phase {
        case .running:
            if let run {
                ProgressView().controlSize(.small)
                DownloadElapsedText(run: run, hubDir: settings.hfHubDir)
                Button("Cancel") { weightDownloads.cancel(run.target) }
                    .buttonStyle(.bordered).controlSize(.regular)
            }

        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
            Button("Retry") { start() }
                .buttonStyle(.bordered).controlSize(.regular)

        case nil, .done:
            if status.cached {
                Text("Cached").font(.caption).foregroundStyle(.green)
                Button("Remove", role: .destructive) { confirmingRemove = true }
                    .buttonStyle(.bordered).controlSize(.regular)
            } else {
                Button("Download") { start() }
                    .buttonStyle(.bordered).controlSize(.regular)
            }
        }
    }

    private func start() {
        weightDownloads.start(model: model, quantize: status.quantize, settings: settings)
    }

    private func logView(_ run: WeightDownloadStore.Run) -> some View {
        ScrollView {
            Text(run.log.isEmpty ? "No output." : run.log)
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .textSelection(.enabled)
        }
        .frame(height: 120)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }
}
