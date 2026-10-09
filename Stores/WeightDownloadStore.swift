import Foundation

/// Settings ▸ Models downloads: an `hf download` of a published repo, or an
/// mflux-save pass that writes a quantized copy.
///
/// The app owns them, not the page, so switching models or closing Settings
/// doesn't stop one (#27). There is at most one run per model, and a run only
/// ever writes to itself, so a run that was cancelled or replaced can't launch
/// or change a newer one's row (#43).
@Observable
final class WeightDownloadStore {
    /// Builds the process a plan runs. Swapped out in tests.
    typealias MakeProcess = (_ plan: Plan, _ settings: AppSettings) throws -> Process

    enum Phase: Equatable {
        case running, done, failed(String)
    }

    /// What a run does, settled when it starts.
    enum Plan: Equatable {
        /// `hf download` of a repo mflux loads directly (Ideogram 4, published
        /// pre-quantized levels).
        case download(repo: String)
        /// `mflux-save` with `args`, writing to `savePath`. `fetchesBase` when
        /// mflux downloads the full-precision weights first.
        case save(args: [String], savePath: URL, fetchesBase: Bool)
    }

    @Observable
    final class Run {
        let model: FluxModelVariant
        /// The level this run fetches: what its row reports, and what Retry
        /// starts again (#26). Not the model's Quantization setting.
        let quantize: Int
        let plan: Plan
        let startedAt = Date()
        var phase: Phase = .running
        var log = ""
        @ObservationIgnored fileprivate var process: Process?
        @ObservationIgnored fileprivate var cancelled = false

        init(model: FluxModelVariant, quantize: Int, plan: Plan) {
            self.model = model
            self.quantize = quantize
            self.plan = plan
        }
    }

    /// The bundled (or Custom Python) `hf` / `mflux-save`.
    private static let toolProcess: MakeProcess = { plan, settings in
        let process = Process()
        switch plan {
        case let .download(repo):
            // The Hugging Face CLI is `hf` now — `huggingface-cli` is a deprecated no-op shim.
            let hf = try settings.toolchain.command(.hf)
            process.executableURL = hf.executableURL
            process.arguments = hf.arguments + ["download", repo]
            process.environment = settings.buildEnvironment()
        case let .save(args, _, _):
            let save = try settings.toolchain.command(.save)
            process.executableURL = save.executableURL
            process.arguments = save.arguments + args
            process.environment = settings.buildEnvironment(interpreter: save.executable)
        }
        return process
    }

    // MARK: - Planning

    /// The download for `model` at `quantize`. A model with a published repo for
    /// the level (Ideogram, Klein Q8, Z-Image Turbo Q4) loads it straight from the
    /// HF cache, so a plain `hf download` is all it needs; anything else is an
    /// mflux-save pass, from local full-precision weights when there are some.
    static func plan(model: FluxModelVariant, quantize: Int, cacheDir: URL, hubDir: URL) -> Plan {
        if let repo = model.preQuantizedRepoID(quantize: quantize) {
            return .download(repo: repo)
        }
        if model.isIdeogram4 {
            return .download(repo: "ideogram-ai/ideogram-4-fp8")
        }
        let savePath = model.savedModelPath(quantize: quantize, in: cacheDir)
        let output = ["--path", savePath.path]
        guard quantize != 0 else {
            return .save(args: ["--model", model.mfluxModelID] + output, savePath: savePath, fetchesBase: true)
        }
        let quantizeArgs = ["--quantize", "\(quantize)"]
        let bf16Saved = model.savedModelPath(quantize: 0, in: cacheDir)
        if FluxModelVariant.hasSavedWeights(at: bf16Saved) {
            return .save(args: ["--model", bf16Saved.path] + quantizeArgs + output, savePath: savePath, fetchesBase: false)
        }
        if model.isOnDisk(quantize: 0, hubDir: hubDir), let bf16Repo = model.bf16HFRepoID {
            return .save(args: ["--model", bf16Repo] + quantizeArgs + output, savePath: savePath, fetchesBase: false)
        }
        return .save(args: ["--model", model.mfluxModelID] + quantizeArgs + output, savePath: savePath, fetchesBase: true)
    }

    /// The hub folder a run's download lands in, and the size it heads for.
    /// For an mflux-save pass that's the base weights mflux fetches, which
    /// aren't always ``FluxModelVariant/bf16HFRepoID`` (Klein resolves to the
    /// black-forest-labs repo). Nil when the run downloads nothing, or before
    /// mflux has created that folder.
    static func progressTarget(of run: Run, hubDir: URL) -> (folder: URL, totalGB: Double)? {
        switch run.plan {
        case let .download(repo):
            (ModelDownloadStore.cacheFolder(repo: repo, hubDir: hubDir), run.model.approximateSizeGB(quantize: run.quantize))
        case let .save(_, _, fetchesBase):
            fetchesBase
                ? run.model.hubCacheFolder(quantize: 0, hubDir: hubDir).map { ($0, run.model.approximateSizeGB(quantize: 0)) }
                : nil
        }
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

    /// The current run for each model: running, or finished and not yet dismissed.
    private(set) var runs: [FluxModelVariant: Run] = [:]
    /// Changes whenever a run puts new weights on disk.
    private(set) var revision = UUID()

    @ObservationIgnored private let makeProcess: MakeProcess

    init(makeProcess: MakeProcess? = nil) {
        self.makeProcess = makeProcess ?? Self.toolProcess
    }

    // MARK: - Runs

    /// Starts fetching `model` at `quantize`, unless it's already downloading.
    /// Replaces a finished run's row.
    func start(model: FluxModelVariant, quantize: Int, settings: AppSettings) {
        guard runs[model]?.phase != .running else { return }
        let plan = Self.plan(
            model: model, quantize: quantize, cacheDir: settings.effectiveMfluxCacheDir, hubDir: settings.hfHubDir
        )
        let run = Run(model: model, quantize: quantize, plan: plan)
        runs[model] = run
        Task { await execute(run, settings: settings) }
    }

    /// Stops `model`'s download (the row's Cancel button). Its row goes once
    /// the process has exited.
    func cancel(_ model: FluxModelVariant) {
        guard let run = runs[model], run.phase == .running else { return }
        run.cancelled = true
        run.process?.stopGracefully()
    }

    /// Clears `model`'s finished row and log, as its page closes. A running
    /// download carries on.
    func dismiss(_ model: FluxModelVariant) {
        if let run = runs[model], run.phase != .running {
            runs[model] = nil
        }
    }

    private func execute(_ run: Run, settings: AppSettings) async {
        switch run.plan {
        case let .download(repo):
            run.log = "▸ Downloading \(repo) into the Hugging Face cache…\n"
            let hubDir = settings.hfHubDir
            await Task.detached(priority: .utility) {
                ModelDownloadStore.removeAbandonedPartials(repo: repo, hubDir: hubDir)
            }.value
        case let .save(_, savePath, _):
            try? FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)
        }
        // Cancelled before there was a process for Cancel to stop.
        guard !run.cancelled, runs[run.model] === run else {
            remove(run)
            return
        }
        let process: Process
        do {
            process = try makeProcess(run.plan, settings)
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
        let chunks = AsyncStream<String> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else if let text = String(data: data, encoding: .utf8) {
                    continuation.yield(text)
                }
            }
            process.terminationHandler = { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish()
                }
            }
        }
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
        switch run.plan {
        case let .download(repo):
            if status == 0 {
                run.log += "\n✓ Cached \(repo)."
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
        case let .save(_, savePath, _):
            if status == 0 {
                let savedFiles = (try? FileManager.default.contentsOfDirectory(
                    at: savePath, includingPropertiesForKeys: nil
                ))?.map(\.lastPathComponent) ?? []
                let files = savedFiles.isEmpty ? "(none found)" : savedFiles.joined(separator: ", ")
                run.log += "\nSaved to: \(savePath.path)\nFiles: \(files)"
                run.phase = .done
                revision = UUID()
            } else if process.terminationReason == .uncaughtSignal || run.cancelled {
                try? FileManager.default.removeItem(at: savePath)
                if run.cancelled {
                    remove(run)
                } else {
                    run.phase = .failed("Process crashed (signal \(status)). Check the log below.")
                }
            } else {
                run.phase = .failed("mflux-save exited with status \(status). Check the log below.")
            }
        }
    }

    /// Drops `run`'s row, unless a newer run has taken its place.
    private func remove(_ run: Run) {
        if runs[run.model] === run {
            runs[run.model] = nil
        }
    }
}
