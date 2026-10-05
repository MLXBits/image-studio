import Foundation

enum ModelDownloadError: LocalizedError, Equatable {
    case failed(repo: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .failed(repo, detail):
            "Couldn't download \(repo). \(detail)"
        }
    }
}

/// Model downloads the app owns, not a panel (#18).
///
/// The Scenario Generator and the Ideogram caption tool fetch their local Gemma
/// model here before running it. Closing the panel, or cancelling the
/// generation, stops the wait but not the download, and the panels show what
/// has landed so far.
@Observable
final class ModelDownloadStore {
    /// Fetches one Hugging Face repo into the cache. Swapped out in tests.
    typealias Fetch = (_ repo: String, _ settings: AppSettings) async throws -> Void

    struct Download: Equatable {
        let startedAt: Date
        var bytesOnDisk: Int64 = 0
    }

    /// A fetch is of one repo into one cache folder: after the models folder
    /// changes, a repo fetched into the old one is fetched again.
    private struct Key: Hashable {
        let repo: String
        let hubDir: URL
    }

    /// `hf download <repo>` through the bundled toolchain, in a process of its own.
    private static let hfDownload: Fetch = { repo, settings in
        let hf = try settings.toolchain.command(.hf)
        let process = Process()
        process.executableURL = hf.executableURL
        process.arguments = hf.arguments + ["download", repo]
        process.environment = settings.buildEnvironment()
        process.standardOutput = FileHandle.nullDevice
        // stderr goes to a file: hf's progress bars would fill a pipe nobody reads.
        let errorLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-download-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        process.standardError = errorHandle
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorLog)
        }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let tail = (try? String(contentsOf: errorLog, encoding: .utf8)).map { String($0.suffix(600)) } ?? ""
            throw ModelDownloadError.failed(repo: repo, detail: tail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Whether a local run of `model` needs it fetched first: a Hugging Face
    /// repo ID, while online.
    static func needsFetch(_ model: String, offline: Bool) -> Bool {
        !offline && !FileAccessPath.isLocal(model) && model.contains("/")
    }

    /// `models--org--name` under the hub cache.
    static func cacheFolder(repo: String, hubDir: URL) -> URL {
        hubDir.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// Bytes in the repo's blobs folder, `.incomplete` files included.
    static func bytesOnDisk(repo: String, hubDir: URL) -> Int64 {
        let blobs = cacheFolder(repo: repo, hubDir: hubDir).appendingPathComponent("blobs", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return entries.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Whether a complete snapshot of the repo is already cached, so a failed
    /// fetch (offline, Hub down) can still run it. An interrupted download
    /// leaves a snapshot without all its weights, which doesn't count.
    static func hasCachedWeights(repo: String, hubDir: URL) -> Bool {
        let snapshots = cacheFolder(repo: repo, hubDir: hubDir).appendingPathComponent("snapshots", isDirectory: true)
        let revisions = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
        return revisions.contains(where: hasWeights)
    }

    /// Every shard the snapshot's index lists, or a `.safetensors` file when
    /// there's no index. `fileExists` follows hf's links, so a link to a blob
    /// that never landed doesn't count.
    private static func hasWeights(_ snapshot: URL) -> Bool {
        let present = ((try? FileManager.default.contentsOfDirectory(atPath: snapshot.path)) ?? [])
            .filter { FileManager.default.fileExists(atPath: snapshot.appendingPathComponent($0).path) }
        let index = snapshot.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let shards = json["weight_map"] as? [String: String] {
            return Set(shards.values).isSubset(of: present)
        }
        return present.contains { $0.hasSuffix(".safetensors") }
    }

    /// Repos downloading now, with how much has landed.
    private(set) var active: [String: Download] = [:]

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var tasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var failures: [Key: Error] = [:]
    /// Repos fetched this launch, which aren't fetched again.
    @ObservationIgnored private var ready: Set<Key> = []

    init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? Self.hfDownload
    }

    /// Returns once `model` is in the cache. That's at once for a local path,
    /// in offline mode, or for a repo already fetched this launch. Otherwise it
    /// starts the download, or joins one in progress, and waits. Cancelling the
    /// caller ends the wait; the download carries on.
    func ensureAvailable(_ model: String, settings: AppSettings) async throws {
        let key = Key(repo: model, hubDir: settings.hfHubDir)
        guard Self.needsFetch(model, offline: settings.hfOffline), !ready.contains(key) else { return }
        if tasks[key] == nil {
            start(key, settings: settings)
        }
        while tasks[key] != nil {
            try await Task.sleep(for: .milliseconds(200))
        }
        if let error = failures[key] {
            throw error
        }
    }

    /// Stops a download (the status row's Stop button).
    func cancel(_ repo: String) {
        for (key, task) in tasks where key.repo == repo {
            task.cancel()
        }
    }

    private func start(_ key: Key, settings: AppSettings) {
        let (repo, hubDir) = (key.repo, key.hubDir)
        failures[key] = nil
        active[repo] = Download(startedAt: Date())
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.active[repo]?.bytesOnDisk = Self.bytesOnDisk(repo: repo, hubDir: hubDir)
            }
        }
        tasks[key] = Task { [weak self] in
            do {
                try await self?.fetch(repo, settings)
                self?.ready.insert(key)
            } catch {
                if !(error is CancellationError), Self.hasCachedWeights(repo: repo, hubDir: hubDir) {
                    self?.ready.insert(key)
                } else {
                    self?.failures[key] = error
                }
            }
            poll.cancel()
            self?.active[repo] = nil
            self?.tasks[key] = nil
        }
    }
}

extension AppSettings {
    static let defaultGemmaModel = "mlx-community/gemma-3-12b-it-8bit"

    /// The Gemma model local runs use: the setting, or the default when it's empty.
    var gemmaModel: String {
        ((gemmaModelPath.isEmpty ? Self.defaultGemmaModel : gemmaModelPath) as NSString).expandingTildeInPath
    }
}
