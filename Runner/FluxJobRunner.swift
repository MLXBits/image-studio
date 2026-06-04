// swiftlint:disable file_length
import AppKit
import Foundation

/// Executes image generation jobs by driving the `mflux-generate-flux2` CLI.
///
/// `FluxJobRunner` picks pending jobs from ``JobStore`` one at a time, spawns the `mflux`
/// process, streams its output into the job's ``FluxJob/log``, and updates job status as the
/// run progresses. Call ``runNext(in:settings:)`` after each job completes to drive the queue
/// forward. Cancel the active job via ``cancel()``.
@Observable
@MainActor
final class FluxJobRunner {
    private(set) var activeJob: FluxJob?
    private(set) var lastCompletedOutputPath: String?
    private(set) var batchImageLanded: Int = 0   // incremented per-seed; ContentView scans gallery on change
    private(set) var sessionCompleted: Int = 0
    private(set) var inSession: Bool = false
    private var runTask: Task<Void, Never>?
    private var currentProcess: Process?
    private var stepwiseTimer: Timer?
    private var batchPollingTask: Task<Void, Never>?

    private static let cacheBase: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MLXBits Image Studio/stepwise", isDirectory: true)
    }()

    // MARK: - Public

    func runNext(in store: JobStore, settings: AppSettings) {
        guard runTask == nil, let job = store.pendingJobs.first else {
            inSession = false
            return
        }
        if !inSession {
            inSession = true
            sessionCompleted = 0
        }
        store.isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(job, settings: settings)
            self.runTask = nil
            if !job.seeds.isEmpty, case .completed = job.status {
                store.expandBatchJob(job)
            }
            store.isRunning = false
            store.save()
            self.runNext(in: store, settings: settings)
        }
    }

    func cancel() {
        currentProcess?.terminate()
    }

    // MARK: - Private execution

    // swiftlint:disable:next cyclomatic_complexity
    private func run(_ job: FluxJob, settings: AppSettings) async {
        activeJob = job
        job.status = .running
        job.startedAt = Date()
        job.log = ""
        job.currentStep = 0

        let stepDir = Self.cacheBase.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: stepDir, withIntermediateDirectories: true)
        startStepwiseWatcher(job: job, dir: stepDir)

        let binaryPath = job.isEditMode ? settings.mfluxEditBinaryPath() : settings.mfluxBinaryPath()
        guard !binaryPath.isEmpty, FileManager.default.fileExists(atPath: binaryPath) else {
            let name = job.isEditMode ? "mflux-generate-flux2-edit" : "mflux-generate-flux2"
            finishJob(job, status: .failed("\(name) not found. Check Settings → Advanced."), stepDir: stepDir)
            return
        }

        // For quantized non-custom models, ensure a local saved copy exists so every subsequent
        // load skips in-memory quantization. The mlx-community pre-quantized repos are preferred
        // when known; otherwise we run mflux-save once to produce a local saved copy.
        if job.quantize > 0, job.model != .custom,
           job.model.preQuantizedRepoID(quantize: job.quantize) == nil {
            let savedPath = job.model.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
            if !FluxModelVariant.hasSavedWeights(at: savedPath) {
                switch await runSave(job: job, savePath: savedPath, settings: settings) {
                case .success:
                    job.statusLine = ""

                case .cancelled:
                    finishJob(job, status: .cancelled, stepDir: stepDir)
                    return

                case .failed:
                    finishJob(job, status: .failed("Failed to save quantized model weights"), stepDir: stepDir)
                    return
                }
            }
        }

        settings.ensureOutputDirExists()
        let isMultiSeed = !job.seeds.isEmpty
        guard let outputTemplate = buildOutputPath(job: job, settings: settings, multiSeed: isMultiSeed) else {
            finishJob(job, status: .failed("Could not create output directory"), stepDir: stepDir)
            return
        }

        let effectiveSeed: Int
        if isMultiSeed {
            effectiveSeed = job.seeds[0]
        } else {
            effectiveSeed = job.seed >= 0 ? job.seed : Int(UInt32.random(in: 0 ..< UInt32.max))
            job.resolvedSeed = effectiveSeed
        }

        let args = buildArgs(job: job, seed: effectiveSeed, outputFile: outputTemplate, stepwiseDir: stepDir, settings: settings)
        job.log += "$ \(binaryPath) \(args.joined(separator: " "))\n\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.environment = settings.buildEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.currentProcess = process

        let stream = AsyncStream<String> { continuation in
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

        // Pre-compute expected output paths for multi-seed so we can poll as each lands.
        let batchPaths: [(seed: Int, path: String)] = isMultiSeed
            ? expandedPaths(from: outputTemplate, seeds: job.seeds)
            : []

        if isMultiSeed {
            startBatchPoller(job: job, paths: batchPaths)
        }

        let jobStartTime = Date()
        job.log += "▸ Loading model...\n"
        job.statusLine = "Loading model…"

        do { try process.run() } catch {
            finishJob(job, status: .failed(error.localizedDescription), stepDir: stepDir)
            return
        }

        var seenFirstStep = false
        var seenLastStep = false
        var loadEndTime: Date?
        var denoiseEndTime: Date?

        for await chunk in stream {
            job.log = appendLog(chunk, to: job.log)
            if let progress = JobProgressParser.parseStep(from: job.log),
               progress.total == job.steps {
                if !seenFirstStep {
                    seenFirstStep = true
                    loadEndTime = Date()
                    let loadSecs = loadEndTime.map { $0.timeIntervalSince(jobStartTime) } ?? 0
                    let label = "▸ Encoding prompt...  (loaded in \(formatDuration(loadSecs)))\n"
                    job.log = insertBeforeLastLine(job.log, text: label)
                }

                if !seenLastStep && progress.current == progress.total {
                    seenLastStep = true
                    denoiseEndTime = Date()
                    if !job.log.hasSuffix("\n") { job.log += "\n" }
                    job.log += "▸ Decoding image...\n"
                }

                job.currentStep = progress.current
                job.totalSteps  = progress.total
            }
        }

        process.waitUntilExit()
        self.currentProcess = nil

        if process.terminationStatus == 0 {
            let totalSecs = Date().timeIntervalSince(jobStartTime)
            let decodeSecs = denoiseEndTime.map { Date().timeIntervalSince($0) }
            let timing = decodeSecs.map { "decoded in \(formatDuration($0)) · " } ?? ""

            if isMultiSeed {
                let paths = batchPaths.map(\.path)
                job.outputPaths = paths
                job.outputThumbnails = paths.map { loadThumbnail(at: $0) ?? Data() }
                job.outputPath = paths.first
                job.thumbnailData = job.outputThumbnails.first
                // Sidecars written progressively by batchPoller; write any missed ones here.
                for item in batchPaths where !FileManager.default.fileExists(atPath: item.path + ".json") {
                    var meta = GenerationMetadata.from(job: job)
                    meta.seed = item.seed
                    MetadataSidecar.write(meta, for: item.path)
                }
                job.log += "▸ Saved \(paths.count) images  (\(timing)total \(formatDuration(totalSecs)))\n"
                if job.completedSeedsInBatch == 0 { lastCompletedOutputPath = paths.first }
            } else {
                job.outputPath = outputTemplate
                job.log += "▸ Saved to: \(outputTemplate)  (\(timing)total \(formatDuration(totalSecs)))\n"
                job.thumbnailData = loadThumbnail(at: outputTemplate)
                MetadataSidecar.write(GenerationMetadata.from(job: job), for: outputTemplate)
                lastCompletedOutputPath = outputTemplate
            }
            finishJob(job, status: .completed, stepDir: stepDir)
        } else if process.terminationReason == .uncaughtSignal {
            finishJob(job, status: .cancelled, stepDir: stepDir)
        } else {
            let lastLine = job.log.components(separatedBy: "\n")
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Unknown error"
            finishJob(job, status: .failed(lastLine), stepDir: stepDir)
        }
    }

    private func finishJob(_ job: FluxJob, status: JobStatus, stepDir: URL) {
        batchPollingTask?.cancel()
        batchPollingTask = nil
        stopStepwiseWatcher()
        try? FileManager.default.removeItem(at: stepDir)
        job.status = status
        job.completedAt = Date()
        job.latestStepwisePath = nil
        if case .running = status { } else {
            activeJob = nil
            sessionCompleted += 1
        }
    }

    // MARK: - One-time quantized model save

    private enum SaveResult { case success, cancelled, failed }

    private func runSave(job: FluxJob, savePath: URL, settings: AppSettings) async -> SaveResult {
        let saveBinary = BinaryDetector.mfluxSave(in: settings.mfluxBinaryDir)
        guard !saveBinary.isEmpty, FileManager.default.fileExists(atPath: saveBinary) else {
            job.log += "⚠️  mflux-save not found — falling back to in-memory quantization.\n"
            return .success  // non-fatal: generate will quantize in-memory instead
        }
        try? FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)
        job.log += "▸ Downloading and saving Q\(job.quantize) weights (one-time)...\n"
        job.statusLine = "Downloading model…"

        let args = ["--model", job.model.mfluxModelID, "--quantize", "\(job.quantize)", "--path", savePath.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: saveBinary)
        process.arguments = args
        process.environment = settings.buildEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.currentProcess = process

        let stream = AsyncStream<String> { continuation in
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
            self.currentProcess = nil
            job.log += "⚠️  mflux-save failed: \(error.localizedDescription)\n"
            return .failed
        }

        for await chunk in stream {
            job.log = appendLog(chunk, to: job.log)
            // Surface the latest download/quantize line (skip the shell command echo)
            if let last = job.log.components(separatedBy: "\n")
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("$") }) {
                job.statusLine = last
            }
        }
        process.waitUntilExit()
        self.currentProcess = nil

        if process.terminationStatus == 0 {
            job.log += "▸ Weights saved.\n"
            return .success
        }
        if process.terminationReason == .uncaughtSignal {
            try? FileManager.default.removeItem(at: savePath)
            return .cancelled
        }
        job.log += "⚠️  mflux-save exited with status \(process.terminationStatus).\n"
        try? FileManager.default.removeItem(at: savePath)
        return .failed
    }

    // MARK: - Stepwise watcher

    private func startStepwiseWatcher(job: FluxJob, dir: URL) {
        stopStepwiseWatcher()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak job] _ in
            guard let self, let job else { return }
            Task { @MainActor in self.pollStepwise(job: job, dir: dir) }
        }
        RunLoop.main.add(timer, forMode: .common)
        stepwiseTimer = timer
    }

    private func stopStepwiseWatcher() {
        stepwiseTimer?.invalidate()
        stepwiseTimer = nil
    }

    private func pollStepwise(job: FluxJob, dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let latest = files
            .filter {
                $0.pathExtension.lowercased() == "png"
                    && !$0.lastPathComponent.contains("composite")
                    && !$0.lastPathComponent.hasPrefix(".")
                    && isPNGComplete(at: $0.path)
            }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return a < b
            }
        if latest?.path != job.latestStepwisePath {
            job.latestStepwisePath = latest?.path
        }
    }

    // MARK: - Batch polling

    private func expandedPaths(from template: String, seeds: [Int]) -> [(seed: Int, path: String)] {
        let url = URL(fileURLWithPath: template)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent().path
        return seeds.map { seed in (seed: seed, path: "\(dir)/\(stem)_seed_\(seed).\(ext)") }
    }

    private func startBatchPoller(job: FluxJob, paths: [(seed: Int, path: String)]) {
        batchPollingTask?.cancel()
        batchPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var found = Set<String>()
            while found.count < paths.count, !Task.isCancelled {
                for item in paths where !found.contains(item.path) {
                    guard FileManager.default.fileExists(atPath: item.path),
                          isPNGComplete(at: item.path) else { continue }
                    found.insert(item.path)
                    var meta = GenerationMetadata.from(job: job)
                    meta.seed = item.seed
                    MetadataSidecar.write(meta, for: item.path)
                    job.completedSeedsInBatch = found.count
                    if found.count == 1 { lastCompletedOutputPath = item.path }
                    batchImageLanded += 1
                }
                if found.count < paths.count {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    // MARK: - Arg building

    private func buildArgs(
        job: FluxJob, seed: Int, outputFile: String, stepwiseDir: URL, settings: AppSettings
    ) -> [String] {
        var args: [String] = []

        if job.model == .custom {
            args += ["--model", job.customModelRepo, "--base-model", job.customBaseModel.mfluxModelID]
        } else if let override = settings.defaults(for: job.model).modelRepoOverride, !override.isEmpty {
            // User-supplied override (HF repo ID or local path): use as-is.
            // No --quantize flag — the repo carries its own quantization metadata.
            args += ["--model", override]
        } else if job.quantize > 0 {
            if let preQuantizedRepo = job.model.preQuantizedRepoID(quantize: job.quantize) {
                // Known mlx-community pre-quantized repo: pass directly, mflux detects stored_q.
                args += ["--model", preQuantizedRepo]
            } else {
                let savedPath = job.model.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
                if FluxModelVariant.hasSavedWeights(at: savedPath) {
                    // Local mflux-saved weights: pass path directly, mflux detects stored_q.
                    args += ["--model", savedPath.path]
                } else {
                    // No saved weights yet (mflux-save may have failed): fall back to in-memory quantization.
                    args += ["--model", job.model.mfluxModelID]
                }
            }
        } else {
            args += ["--model", job.model.mfluxModelID]
        }

        args += ["--prompt", job.prompt]

        let supportsNeg = job.model.supportsNegativePrompt
        if supportsNeg, !job.negativePrompt.isEmpty {
            args += ["--negative-prompt", job.negativePrompt]
        }

        args += [
            "--width", "\(job.width)",
            "--height", "\(job.height)",
            "--steps", "\(job.steps)",
            "--guidance", String(format: "%.2f", job.guidance),
            "--output", outputFile,
        ]

        if job.seeds.isEmpty {
            args += ["--seed", "\(seed)"]
        } else {
            args += ["--seed"] + job.seeds.map { "\($0)" }
        }

        // Only pass --quantize when falling back to in-memory quantization (BF16 base model).
        // Overrides, pre-quantized repos, and locally saved weights carry stored_q in metadata.
        if job.quantize > 0 {
            let hasOverride = !(settings.defaults(for: job.model).modelRepoOverride ?? "").isEmpty
            let hasPreQuantizedRepo = job.model != .custom && job.model.preQuantizedRepoID(quantize: job.quantize) != nil
            let savedPath = job.model.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
            let hasSaved = job.model != .custom && FluxModelVariant.hasSavedWeights(at: savedPath)
            if !hasOverride && !hasPreQuantizedRepo && !hasSaved {
                args += ["--quantize", "\(job.quantize)"]
            }
        }
        if job.lowRam { args.append("--low-ram") }
        if settings.mlxCacheLimitGB > 0 {
            args += ["--mlx-cache-limit-gb", String(format: "%.1f", settings.mlxCacheLimitGB)]
        }

        if job.isEditMode {
            if !job.editImagePaths.isEmpty {
                args += ["--image-paths"] + job.editImagePaths
            }
        } else if !job.imagePath.isEmpty {
            args += [
                "--image-path", job.imagePath,
                "--image-strength", String(format: "%.2f", job.imageStrength),
            ]
        }

        let enabledLoras = job.loras.filter { $0.enabled && $0.isValid }
        if !enabledLoras.isEmpty {
            args += ["--lora-paths"] + enabledLoras.map(\.path)
            args += ["--lora-scales"] + enabledLoras.map { String(format: "%.2f", $0.strength) }
        }

        args += ["--stepwise-image-output-dir", stepwiseDir.path]

        return args
    }

    private func buildOutputPath(job: FluxJob, settings: AppSettings, multiSeed: Bool = false) -> String? {
        let useBoard = !job.board.isEmpty && job.board != "Default"
        let dir = useBoard ? "\(settings.outputDir)/\(job.board)" : settings.outputDir
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        } catch { return nil }
        let ts = Int(Date().timeIntervalSince1970)
        if multiSeed {
            // No {seed} placeholder — mflux rewrites multi-seed output paths itself:
            // it appends _seed_{seed} to the stem, so image_ts.png → image_ts_seed_42.png
            return "\(dir)/image_\(ts).png"
        }
        let seedLabel = job.seed == -1 ? "rnd" : "\(job.seed)"
        return "\(dir)/image_\(ts)_\(seedLabel).png"
    }

    private func isPNGComplete(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        guard size >= 12 else { return false }
        handle.seek(toFileOffset: size - 4)
        let tail = handle.readDataToEndOfFile()
        // PNG IEND chunk CRC — present only in a fully written PNG
        return tail.count == 4 && tail[0] == 0xAE && tail[1] == 0x42 && tail[2] == 0x60 && tail[3] == 0x82
    }

    private func loadThumbnail(at path: String) -> Data? {
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        let imgSize = img.size
        guard imgSize.width > 0, imgSize.height > 0 else { return nil }
        let side = min(imgSize.width, imgSize.height)
        let srcRect = NSRect(
            x: (imgSize.width - side) / 2,
            y: (imgSize.height - side) / 2,
            width: side, height: side
        )
        let size = CGSize(width: 200, height: 200)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: size), from: srcRect, operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        guard let tiff = thumb.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    // Insert `text` immediately before the last (possibly incomplete) line.
    // Used to place stage markers ahead of tqdm output that has no trailing newline.
    private func insertBeforeLastLine(_ log: String, text: String) -> String {
        if let lastNewline = log.lastIndex(of: "\n") {
            let split = log.index(after: lastNewline)
            let head = String(log[...lastNewline])   // includes the \n
            let tail = String(log[split...])          // "" when \n was the last char
            return head + text + tail
        }
        return text + log
    }

    private func appendLog(_ chunk: String, to log: String) -> String {
        var result = log
        for char in chunk {
            if char == "\r" {
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
}
