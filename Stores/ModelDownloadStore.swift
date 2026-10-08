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
        let hubDir = settings.hfHubDir
        await Task.detached(priority: .utility) { removeAbandonedPartials(repo: repo, hubDir: hubDir) }.value
        try Task.checkCancellation()
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
                    // Cancelled before the launch: onCancel found nothing to stop.
                    if Task.isCancelled {
                        process.stopGracefully()
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.stopGracefully()
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
    nonisolated static func cacheFolder(repo: String, hubDir: URL) -> URL {
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

    /// Deletes the repo's `.incomplete` files that no download is writing.
    /// hf names each attempt's partial `<etag>.<random>.incomplete`, so a retry
    /// never resumes one, and a download killed before Python could clean up
    /// leaves it behind. hf holds `.locks/<repo folder>/<etag>.lock` while it
    /// downloads that blob, so a partial whose lock is free is abandoned.
    /// (`hf cache prune` deletes live partials too, and old revisions.)
    nonisolated static func removeAbandonedPartials(repo: String, hubDir: URL) {
        removeAbandonedPartials(in: cacheFolder(repo: repo, hubDir: hubDir), hubDir: hubDir)
    }

    /// The same, for every repo in the cache: partials from a force quit, a
    /// crash, or an mflux run that fetched its own weights.
    nonisolated static func removeAbandonedPartials(hubDir: URL) {
        let repos = (try? FileManager.default.contentsOfDirectory(
            at: hubDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        for repo in repos {
            removeAbandonedPartials(in: repo, hubDir: hubDir)
        }
    }

    nonisolated private static func removeAbandonedPartials(in repoFolder: URL, hubDir: URL) {
        let blobs = repoFolder.appendingPathComponent("blobs", isDirectory: true)
        let locks = hubDir.appendingPathComponent(".locks/\(repoFolder.lastPathComponent)", isDirectory: true)
        let partials = ((try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "incomplete" }
        for partial in partials {
            let etag = partial.lastPathComponent.prefix { $0 != "." }
            whileHoldingFreeLock(locks.appendingPathComponent("\(etag).lock")) {
                try? FileManager.default.removeItem(at: partial)
            }
        }
    }

    /// Runs `body` holding `lock`'s flock, when no other process holds it. A
    /// missing lock file is free; one we can't open is not.
    nonisolated private static func whileHoldingFreeLock(_ lock: URL, _ body: () -> Void) {
        let fd = open(lock.path, O_RDONLY)
        guard fd >= 0 else {
            if errno == ENOENT {
                body()
            }
            return
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
        body()
        flock(fd, LOCK_UN)
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

extension Process {
    /// Stops a Python tool so its cleanup runs: SIGINT first (hf then deletes
    /// its partial download; SIGTERM would kill it before that), then SIGTERM
    /// if it's still running after `grace`.
    nonisolated func stopGracefully(grace: Duration = .seconds(5)) {
        guard isRunning else { return }
        interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace / .seconds(1)) { [self] in
            if isRunning {
                terminate()
            }
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
