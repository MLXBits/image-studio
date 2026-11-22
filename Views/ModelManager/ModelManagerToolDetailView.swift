import SwiftUI

/// The Models window's pane for SeedVR2, the upscaler: one download per size.
struct SeedVR2DetailView: View {
    struct Size {
        let label: String
        let name: String
        let is7B: Bool
    }

    static let sizes = [
        Size(label: "3B", name: "seedvr2-3b", is7B: false), Size(label: "7B", name: "seedvr2-7b", is7B: true),
    ]

    @Environment(AppSettings.self) private var settings
    @Environment(WeightDownloadStore.self) private var weightDownloads
    /// mflux's download specs by name, from the window's probe; nil until it answers or if it fails.
    let specs: [String: HFDownloadSpec]?
    @State private var confirmingRemove = false

    var body: some View {
        // Reading the revision re-evaluates the cached flags when a download or removal finishes.
        let _ = weightDownloads.revision // swiftlint:disable:this redundant_discardable_let
        ToolDetailLayout(
            title: "SeedVR2",
            blurb: "Upscales an existing image. 3B is fast; 7B is sharper and slower."
                + " Both are quantized in memory, so there's one download per size."
        ) {
            ForEach(Self.sizes, id: \.name) { size in
                sizeRow(size)
            }
            Divider()
            Button("Remove SeedVR2 weights", role: .destructive) { confirmingRemove = true }
                .disabled(specs == nil || isDownloading || !Self.sizes.contains { cached($0.name) })
        }
        .alert("Delete SeedVR2 weights?", isPresented: $confirmingRemove) {
            Button("Delete", role: .destructive) {
                if !isDownloading, let repo = specs?.values.first?.repo {
                    Task { await weightDownloads.deleteRepo(repo, settings: settings) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes both the 3B and 7B SeedVR2 weights from disk. You can re-download them later.")
        }
    }

    private var isDownloading: Bool {
        Self.sizes.contains { weightDownloads.runs[.seedVR2(is7B: $0.is7B)]?.phase == .running }
    }

    private func cached(_ name: String) -> Bool {
        specs?[name].map { ModelInventory.isCached($0, hubDir: settings.hfHubDir) } ?? false
    }

    private func sizeRow(_ size: Size) -> some View {
        let target = DownloadTarget.seedVR2(is7B: size.is7B)
        let run = weightDownloads.runs[target]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(size.label).fontWeight(.medium).frame(width: 56, alignment: .leading)
                Spacer(minLength: 8)
                if let spec = specs?[size.name] {
                    DownloadStateView(
                        phase: run?.phase, cached: cached(size.name),
                        start: { weightDownloads.start(target, spec: spec, expectedGB: 0, settings: settings) },
                        cancel: { weightDownloads.cancel(target) },
                        remove: nil,
                        progress: Group {
                            if let run {
                                DownloadElapsedText(run: run, hubDir: settings.hfHubDir)
                            }
                        }
                    )
                } else {
                    Text("Downloads on first upscale").font(.caption).foregroundStyle(.secondary)
                }
            }
            if case let .failed(message)? = run?.phase, let run {
                DownloadFailureView(message: message, log: run.log)
            }
        }
    }
}

/// The Models window's pane for Gemma, the local language model behind captions and scenarios.
struct GemmaDetailView: View {
    private static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    @Environment(AppSettings.self) private var settings
    @Environment(WeightDownloadStore.self) private var weightDownloads
    @Environment(ModelDownloadStore.self) private var modelDownloads
    @State private var confirmingRemove = false
    @State private var downloadError: String?

    private var repo: String {
        settings.gemmaModel
    }

    private var phase: WeightDownloadStore.Phase? {
        if modelDownloads.active[repo] != nil {
            return .running
        }
        return downloadError.map { .failed($0) }
    }

    var body: some View {
        // Reading the revision re-evaluates the cached flag when a removal finishes.
        let _ = weightDownloads.revision // swiftlint:disable:this redundant_discardable_let
        ToolDetailLayout(
            title: "Gemma",
            blurb: "The local language model behind the Scenario Generator and Ideogram captions."
        ) {
            Text(repo).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if FileAccessPath.isLocal(repo) {
                Text("Local model — managed outside the app").foregroundStyle(.secondary)
            } else {
                row
            }
        }
        .alert("Delete Gemma weights?", isPresented: $confirmingRemove) {
            Button("Delete", role: .destructive) {
                let repo = repo
                guard modelDownloads.active[repo] == nil else { return }
                Task {
                    await weightDownloads.deleteRepo(repo, settings: settings)
                    modelDownloads.forget(repo)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the Gemma weights from disk. They download again the next time they are needed.")
        }
    }

    private var row: some View {
        let hubDir = settings.hfHubDir
        let cached = ModelDownloadStore.hasCachedWeights(repo: repo, hubDir: hubDir)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if cached {
                    Text(Self.gigabytes(ModelDownloadStore.bytesOnDisk(repo: repo, hubDir: hubDir)))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                DownloadStateView(
                    phase: phase, cached: cached, start: start,
                    cancel: { modelDownloads.cancel(repo) },
                    remove: { confirmingRemove = true },
                    progress: downloadingText
                )
            }
            if case let .failed(message)? = phase {
                DownloadFailureView(message: message, log: nil)
            }
        }
    }

    private var downloadingText: some View {
        let bytes = modelDownloads.active[repo]?.bytesOnDisk ?? 0
        return Text("Downloading…" + (bytes > 0 ? " · \(Self.gigabytes(bytes))" : ""))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func start() {
        downloadError = nil
        let repo = repo
        Task {
            do {
                try await modelDownloads.ensureAvailable(repo, settings: settings)
            } catch is CancellationError {
                // The person pressed Cancel: not a failure.
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }
}

/// Title, blurb and a body of rows: the frame both tool panes share.
private struct ToolDetailLayout<Content: View>: View {
    let title: String
    let blurb: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.title2.bold())
                Text(blurb)
                Divider()
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}
