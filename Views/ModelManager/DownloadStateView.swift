import SwiftUI

/// The trailing half of a Models window download row: progress and Cancel while running,
/// Failed and Retry after an error, else Cached with Remove or a Download button.
struct DownloadStateView<Progress: View>: View {
    let phase: WeightDownloadStore.Phase?
    let cached: Bool
    let start: () -> Void
    let cancel: () -> Void
    let remove: () -> Void
    let progress: Progress

    var body: some View {
        switch phase {
        case .running:
            ProgressView().controlSize(.small)
            progress
            Button("Cancel", action: cancel)
                .buttonStyle(.bordered).controlSize(.regular)

        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
            Button("Retry", action: start)
                .buttonStyle(.bordered).controlSize(.regular)

        case nil, .done:
            if cached {
                Text("Cached").font(.caption).foregroundStyle(.green)
                Button("Remove", role: .destructive, action: remove)
                    .buttonStyle(.bordered).controlSize(.regular)
            } else {
                Button("Download", action: start)
                    .buttonStyle(.bordered).controlSize(.regular)
            }
        }
    }
}

/// A failed download's message, with its log in a disclosure when there is one.
struct DownloadFailureView: View {
    let message: String
    let log: String?

    var body: some View {
        Text(message).font(.caption).foregroundStyle(.red)
        if let log {
            DisclosureGroup("Log") {
                ScrollView {
                    Text(log.isEmpty ? "No output." : log)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .textSelection(.enabled)
                }
                .frame(height: 120)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
            .font(.caption)
        }
    }
}
