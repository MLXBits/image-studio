import AppKit
import SwiftUI

/// A failed run: a one-line summary of the cause, Retry / Load Settings / Copy Log,
/// then the full log (or the error, when there is no log) scrolled to the end.
/// With `repoURL`, a gated-repo failure also links to the model page, where the
/// user accepts its license.
struct FailedJobView: View {
    var title = "Generation failed"
    let message: String
    let log: String
    var repoURL: URL?
    var onRetry: (() -> Void)?
    var onLoadSettings: (() -> Void)?

    private var logText: String {
        log.isEmpty ? message : log
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.headline)
                    Spacer()
                    if let repoURL, FailureSummary.isGatedRepo(message: message, log: log) {
                        Link("Accept Terms on HuggingFace", destination: repoURL)
                            .font(.caption)
                    }
                }
                Text(FailureSummary.line(message: message, log: log))
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(FailureSummary.line(message: message, log: log))
                HStack(spacing: 8) {
                    if let onRetry {
                        Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                    }
                    if let onLoadSettings {
                        Button("Load Settings", systemImage: "slider.horizontal.3", action: onLoadSettings)
                            .help("Load this job's settings into the form")
                    }
                    Button("Copy Log", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(logText, forType: .string)
                    }
                }
                .controlSize(.small)
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    Color.clear.frame(height: 1).id("errEnd")
                }
                .onAppear { proxy.scrollTo("errEnd") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
