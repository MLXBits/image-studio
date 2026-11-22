import SwiftUI

/// The trailing half of a Models window download row: progress and Cancel while running,
/// Failed and Retry after an error, else Cached with Remove or a Download button.
struct DownloadStateView<Progress: View>: View {
    let phase: WeightDownloadStore.Phase?
    let cached: Bool
    let start: () -> Void
    let cancel: () -> Void
    /// nil shows Cached without a Remove button.
    let remove: (() -> Void)?
    let progress: Progress
    /// False greys out Download, e.g. while HF offline mode would make it do nothing.
    var canStart = true

    var body: some View {
        switch phase {
        case .running:
            DownloadRunningView(cancel: cancel, progress: progress)

        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
            Button("Retry", action: start)
                .buttonStyle(.bordered).controlSize(.regular)

        case nil, .done:
            if cached {
                Text("Cached").font(.caption).foregroundStyle(.green)
                if let remove {
                    Button("Remove", role: .destructive, action: remove)
                        .buttonStyle(.bordered).controlSize(.regular)
                }
            } else {
                Button("Download", action: start)
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(!canStart)
            }
        }
    }
}

/// A running download's spinner, progress text and Cancel.
struct DownloadRunningView<Progress: View>: View {
    let cancel: () -> Void
    let progress: Progress

    var body: some View {
        ProgressView().controlSize(.small)
        progress
        Button("Cancel", action: cancel)
            .buttonStyle(.bordered).controlSize(.regular)
    }
}

/// Shown once per pane while a download runs.
struct BackgroundDownloadCaption: View {
    var body: some View {
        Text("You can close this window \u{2014} the download continues.")
            .font(.caption2).foregroundStyle(.tertiary)
    }
}

/// A failed download's message, with its log in a disclosure when there is one.
struct DownloadFailureView: View {
    private static let endMarker = "log-end"

    let message: String
    let log: String?

    var body: some View {
        Text(message).font(.caption).foregroundStyle(.red)
        if let log {
            DisclosureGroup("Log") {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Text(log.isEmpty ? "No output." : log)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .textSelection(.enabled)
                            Color.clear.frame(height: 1).id(Self.endMarker)
                        }
                    }
                    .onAppear { proxy.scrollTo(Self.endMarker, anchor: .bottom) }
                    .onChange(of: log) { proxy.scrollTo(Self.endMarker, anchor: .bottom) }
                }
                .frame(height: 120)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
            .font(.caption)
        }
    }
}
