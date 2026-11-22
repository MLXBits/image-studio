import Foundation

/// What an `hf download` fetches: a repo, optionally pinned to a revision and
/// narrowed to files matching `include` patterns.
nonisolated struct HFDownloadSpec: Hashable, Sendable {
    let repo: String
    let revision: String?
    let include: [String]
}

/// A probe's answer may omit `include`, which then means "the whole repo".
nonisolated extension HFDownloadSpec: Decodable {
    private enum CodingKeys: String, CodingKey {
        case repo, revision, include
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decode(String.self, forKey: .repo)
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        include = try container.decodeIfPresent([String].self, forKey: .include) ?? []
    }
}

/// What a download is for. Each target downloads independently of the others.
enum DownloadTarget: Hashable {
    case weights(FluxModelVariant, quantize: Int)
    case seedVR2(is7B: Bool)
}

/// Model downloads: an `hf download` of the mflux-community repo a model loads
/// at a precision (``FluxModelVariant/publishedRepoID(quantize:)``), or another
/// ``HFDownloadSpec``.
///
/// The app owns them, not the page, so switching models or closing a window
/// doesn't stop one (#27). There is at most one run per target, and a run only
/// ever writes to itself, so a run that was cancelled or replaced can't launch
/// or change a newer one's row (#43).
@Observable
final class WeightDownloadStore {
    /// Builds the process that downloads a repo. Swapped out in tests.
    typealias MakeProcess = (_ spec: HFDownloadSpec, _ settings: AppSettings) throws -> Process

    enum Phase: Equatable {
        case running, done, failed(String)
    }

    @Observable
    final class Run {
        /// What this run is for. For weights, the level it fetches is part of
        /// it: what the row reports, and what Retry starts again (#26).
        let target: DownloadTarget
        let spec: HFDownloadSpec
        /// The size the download heads for, in GB.
        let expectedGB: Double
        /// The repo this run downloads.
        var repo: String {
            spec.repo
        }

        let startedAt = Date()
        var phase: Phase = .running
        var log = ""
        @ObservationIgnored fileprivate var process: Process?
        @ObservationIgnored fileprivate var cancelled = false

        init(target: DownloadTarget, spec: HFDownloadSpec, expectedGB: Double) {
            self.target = target
            self.spec = spec
            self.expectedGB = expectedGB
        }
    }

    /// The bundled (or Custom Python) `hf`.
    private static let toolProcess: MakeProcess = { spec, settings in
        // The Hugging Face CLI is `hf` now — `huggingface-cli` is a deprecated no-op shim.
        let hf = try settings.toolchain.command(.hf)
        let process = Process()
        process.executableURL = hf.executableURL
        process.arguments = hf.arguments + downloadArgs(spec)
        process.environment = settings.buildEnvironment()
        return process
    }

    /// The `hf` arguments for `spec`.
    static func downloadArgs(_ spec: HFDownloadSpec) -> [String] {
        var args = ["download", spec.repo]
        if let revision = spec.revision {
            args += ["--revision", revision]
        }
        for pattern in spec.include {
            args += ["--include", pattern]
        }
        return args
    }

    // MARK: - Progress

    /// The hub folder a run's download lands in, and the size it heads for.
    static func progressTarget(of run: Run, hubDir: URL) -> (folder: URL, totalGB: Double) {
        (ModelDownloadStore.cacheFolder(repo: run.repo, hubDir: hubDir), run.expectedGB)
    }

    /// The `hf cache rm` arguments that delete `repo` from the hub cache.
    /// huggingface_hub links a repo's blobs into hub/blobs/, a store shared
    /// across the whole cache, so removing the repo folder by hand leaves the
    /// weights behind and the next `hf download` relinks them instead of
    /// fetching. `hf cache rm` frees them once no other repo uses them.
    static func removeArgs(repo: String, hubDir: URL) -> [String] {
        ["cache", "rm", "model/\(repo)", "--yes", "--cache-dir", hubDir.path]
    }

    /// Appends tool output to a log the way a terminal shows it: `\r` rewinds
    /// the line, and an ANSI cursor-up removes it (hf's stacked progress bars).
    static func appendLog(_ chunk: String, to log: String) -> String {
        var result = log
        var idx = chunk.startIndex
        while idx < chunk.endIndex {
            let char = chunk[idx]
            idx = chunk.index(after: idx)
            if char == "\u{1B}" {
                // ESC — consume the full CSI sequence \x1b[<params><letter>
                guard idx < chunk.endIndex, chunk[idx] == "[" else { continue }
                idx = chunk.index(after: idx)
                while idx < chunk.endIndex && !chunk[idx].isLetter {
                    idx = chunk.index(after: idx)
                }
                guard idx < chunk.endIndex else { continue }
                let cmd = chunk[idx]
                idx = chunk.index(after: idx)
                if cmd == "A" {
                    // Cursor up: remove current line and the \n above it, moving to end of previous line
                    if let nl = result.lastIndex(of: "\n") {
                        result = String(result[result.startIndex ..< nl])
                    } else {
                        result = ""
                    }
                }
            } else if char == "\r" {
                if let nl = result.lastIndex(of: "\n") {
                    result = String(result[...nl])
                } else {
                    result = ""
                }
            } else {
                result.append(char)
            }
        }
        return result
    }

    /// The current run for each target: running, or finished and not yet dismissed.
    private(set) var runs: [DownloadTarget: Run] = [:]
    /// Changes whenever a run puts new weights on disk, or a delete removes them.
    private(set) var revision = UUID()

    @ObservationIgnored private let makeProcess: MakeProcess

    init(makeProcess: MakeProcess? = nil) {
        self.makeProcess = makeProcess ?? Self.toolProcess
    }

    // MARK: - Runs

    /// Starts fetching `model` at `quantize`, unless it's already downloading or
    /// has no published repo there (`custom`). Replaces a finished run's row.
    func start(model: FluxModelVariant, quantize: Int, settings: AppSettings) {
        guard let repo = model.publishedRepoID(quantize: quantize) else { return }
        start(
            .weights(model, quantize: quantize),
            spec: HFDownloadSpec(repo: repo, revision: nil, include: []),
            expectedGB: model.approximateSizeGB(quantize: quantize),
            settings: settings
        )
    }

    /// Starts fetching `spec` for `target`, unless that target is already
    /// downloading. Replaces a finished run's row.
    func start(_ target: DownloadTarget, spec: HFDownloadSpec, expectedGB: Double, settings: AppSettings) {
        guard runs[target]?.phase != .running else { return }
        let run = Run(target: target, spec: spec, expectedGB: expectedGB)
        runs[target] = run
        Task { await execute(run, settings: settings) }
    }

    /// Stops `target`'s download (the row's Cancel button). Its row goes once
    /// the process has exited.
    func cancel(_ target: DownloadTarget) {
        guard let run = runs[target], run.phase == .running else { return }
        run.cancelled = true
        run.process?.stopGracefully()
    }

    /// Clears `target`'s finished row and log. A running download carries on.
    func dismiss(_ target: DownloadTarget) {
        if let run = runs[target], run.phase != .running {
            runs[target] = nil
        }
    }

    /// Clears every finished run of `model`, as the Models window leaves it.
    func dismissFinished(_ model: FluxModelVariant) {
        for (target, _) in runs {
            if case let .weights(variant, _) = target, variant == model {
                dismiss(target)
            }
        }
    }

    /// Clears every finished SeedVR2 run, as the Models window leaves its row.
    func dismissFinishedSeedVR2() {
        for (target, _) in runs {
            if case .seedVR2 = target {
                dismiss(target)
            }
        }
    }

    /// Drops every run that isn't running.
    func dismissFinished() {
        runs = runs.filter { $0.value.phase == .running }
    }

    /// Deletes `model`'s weights at `quantize`: any legacy mflux-save folder the
    /// app's old save pass wrote, and its hub cache repo through ``deleteRepo(_:settings:)``.
    func delete(model: FluxModelVariant, quantize: Int, settings: AppSettings) async {
        try? FileManager.default.removeItem(at: model.savedModelPath(quantize: quantize, in: settings.effectiveMfluxCacheDir))
        let hubDir = settings.hfHubDir
        if let folder = model.hubCacheFolder(quantize: quantize, hubDir: hubDir),
           let repo = HFCacheVerdictStore.repoID(cacheFolder: folder.lastPathComponent) {
            await deleteRepo(repo, settings: settings)
        } else {
            revision = UUID()
        }
    }

    /// Deletes `repo` from the hub cache through `hf cache rm`, removing its
    /// folder by hand if hf can't run (`hf cache prune` reclaims what that
    /// leaves in the shared store). Bumps ``revision``.
    func deleteRepo(_ repo: String, settings: AppSettings) async {
        let hubDir = settings.hfHubDir
        let args = Self.removeArgs(repo: repo, hubDir: hubDir)
        if await !runHF(args, settings: settings) {
            try? FileManager.default.removeItem(at: ModelDownloadStore.cacheFolder(repo: repo, hubDir: hubDir))
        }
        revision = UUID()
    }

    /// Runs the bundled `hf` with `args` to completion. True if it exited 0.
    private func runHF(_ args: [String], settings: AppSettings) async -> Bool {
        guard let hf = try? settings.toolchain.command(.hf) else { return false }
        let process = Process()
        process.executableURL = hf.executableURL
        process.arguments = hf.arguments + args
        process.environment = settings.buildEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    private func execute(_ run: Run, settings: AppSettings) async {
        let repo = run.repo
        run.log = "▸ Downloading \(repo) into the Hugging Face cache…\n"
        let hubDir = settings.hfHubDir
        await Task.detached(priority: .utility) {
            ModelDownloadStore.removeAbandonedPartials(repo: repo, hubDir: hubDir)
        }.value
        // Cancelled before there was a process for Cancel to stop.
        guard !run.cancelled, runs[run.target] === run else {
            remove(run)
            return
        }
        let process: Process
        do {
            process = try makeProcess(run.spec, settings)
        } catch {
            run.phase = .failed(error.localizedDescription)
            return
        }
        guard await stream(process, into: run) else { return }
        finish(run, process: process)
    }

    /// Runs `process` with stdout and stderr streamed into the run's log.
    /// Returns false, with the run failed, if it couldn't launch; otherwise
    /// returns once it has exited.
    private func stream(_ process: Process, into run: Run) async -> Bool {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let chunks = TextChunkDecoder.stream(reading: pipe, endingWith: process)
        do { try process.run() } catch {
            run.phase = .failed(error.localizedDescription)
            return false
        }
        run.process = process
        for await chunk in chunks {
            run.log = Self.appendLog(chunk, to: run.log)
        }
        process.waitUntilExit()
        run.process = nil
        return true
    }

    private func finish(_ run: Run, process: Process) {
        let status = process.terminationStatus
        if status == 0 {
            run.log += "\n✓ Cached \(run.repo)."
            run.phase = .done
            revision = UUID()
        } else if run.cancelled {
            // Stopped with SIGINT, hf exits with status 1 ("Aborted!").
            remove(run)
        } else if process.terminationReason == .uncaughtSignal {
            run.phase = .failed("Download interrupted. Check the log below.")
        } else {
            run.phase = .failed("hf exited with status \(status). Check the log below.")
        }
    }

    /// Drops `run`'s row, unless a newer run has taken its place.
    private func remove(_ run: Run) {
        if runs[run.target] === run {
            runs[run.target] = nil
        }
    }
}
