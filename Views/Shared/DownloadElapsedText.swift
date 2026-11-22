import SwiftUI

/// "Downloading… 1m 05s · 4.4 / 27 GB" for a running weight download, ticking once a second.
/// `hf download` emits noisy parallel progress bars that don't render well in a plain
/// log, so the byte count is polled from the run's on-disk payload.
struct DownloadElapsedText: View {
    let run: WeightDownloadStore.Run
    let hubDir: URL

    var body: some View {
        TimelineView(.periodic(from: run.startedAt, by: 1)) { ctx in
            let elapsed = Int(ctx.date.timeIntervalSince(run.startedAt))
            let mm = elapsed / 60
            let ss = elapsed % 60
            let time = "\(mm > 0 ? "\(mm)m " : "")\(String(format: "%02d", ss))s"
            Text("Downloading… \(time)\(downloadedSuffix)")
                .lineLimit(1)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// " · 4.4 / 27 GB" while the run's download is landing, polled from its blobs
    /// dir (includes in-flight `.incomplete` files). Empty until bytes have landed.
    private var downloadedSuffix: String {
        let target = WeightDownloadStore.progressTarget(of: run, hubDir: hubDir)
        let bytes = ModelDownloadStore.blobBytes(in: target.folder)
        guard bytes > 0 else { return "" }
        let gb = Double(bytes) / 1_073_741_824
        return target.totalGB > 0
            ? " · \(String(format: "%.1f", gb)) / \(String(format: "%.0f", target.totalGB)) GB"
            : " · \(String(format: "%.1f", gb)) GB"
    }
}
