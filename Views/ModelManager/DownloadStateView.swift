import SwiftUI

/// The trailing half of a Models window download row: progress and Cancel while running,
/// Failed and Retry after an error, else Remove or a Download button. A cached row says so
/// with ``View/cachedRowHighlight(_:)``, not a label.
struct DownloadStateView<Progress: View>: View {
    let phase: WeightDownloadStore.Phase?
    let cached: Bool
    let start: () -> Void
    let cancel: () -> Void
    /// nil leaves a cached row without a Remove button.
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
                .fixedSize()
            Button("Retry", action: start)
                .modelManagerButton()
                .disabled(!canStart)

        case nil, .done:
            if cached {
                if let remove {
                    Button("Remove", role: .destructive, action: remove)
                        .modelManagerButton()
                }
            } else {
                Button("Download", action: start)
                    .modelManagerButton()
                    .disabled(!canStart)
            }
        }
    }
}

extension View {
    /// A Models window row button: bordered, regular size, and never squeezed into "Do…"
    /// by a narrow pane (the pane's minimum width leaves room for it instead).
    func modelManagerButton() -> some View {
        buttonStyle(.bordered).controlSize(.regular).fixedSize()
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
            .modelManagerButton()
    }
}

extension View {
    /// The faint green wash on a Models window row whose weights are on disk.
    func cachedRowHighlight(_ cached: Bool) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(cached ? Color.green.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
