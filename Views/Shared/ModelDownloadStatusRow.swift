import SwiftUI

/// While the app downloads `model` (``ModelDownloadStore``): how much has
/// landed, a Stop button, and a note that closing the window doesn't stop it (#18).
struct ModelDownloadStatusRow: View {
    /// "2.1 GB · 1m 05s", or just the time before any bytes land.
    static func describe(bytes: Int64, since start: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        let minutes = elapsed / 60
        let time = (minutes > 0 ? "\(minutes)m " : "") + String(format: "%02ds", elapsed % 60)
        guard bytes > 0 else { return time }
        return String(format: "%.1f GB · ", Double(bytes) / 1_073_741_824) + time
    }

    @Environment(ModelDownloadStore.self) private var downloads
    let model: String

    var body: some View {
        if let download = downloads.active[model] {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: download.startedAt, by: 1)) { context in
                        Text("Downloading \(model)… "
                            + Self.describe(bytes: download.bytesOnDisk, since: download.startedAt, now: context.date))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    Spacer()
                    Button("Stop") { downloads.cancel(model) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("First use only. It keeps going if you close this window.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
