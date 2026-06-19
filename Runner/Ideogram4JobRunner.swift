// swiftlint:disable file_length
import AppKit
import Foundation

/// Executes Ideogram 4 generation jobs by driving the `mflux-generate-ideogram4` CLI.
@Observable
@MainActor
final class Ideogram4JobRunner {
    // MARK: - Types

    private enum SaveResult { case success, cancelled, failed }

    private struct RunContext {
        let seed: Int
        let outputFile: String
        let stepwiseDir: URL
        let promptFileURL: URL?
    }

    private static let cacheBase: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.mlxbits.image-studio/stepwise-ideogram4", isDirectory: true)
    }()

    private(set) var activeJob: Ideogram4Job?
    private(set) var lastCompletedOutputPath: String?
    private(set) var batchImageLanded: Int = 0
    private(set) var sessionCompleted: Int = 0
    private(set) var inSession: Bool = false
    private var runTask: Task<Void, Never>?
    private var currentProcess: Process?
    private var stepwiseSource: (any DispatchSourceProtocol)?
    private var batchPollingTask: Task<Void, Never>?

    // MARK: - Public

    func runNext(in store: Ideogram4JobStore, settings: AppSettings) {
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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func run(_ job: Ideogram4Job, settings: AppSettings) async {
        activeJob = job
        job.status = .running
        job.startedAt = Date()
        job.log = ""
        job.currentStep = 0

        let stepDir = Self.cacheBase.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: stepDir, withIntermediateDirectories: true)
        startStepwiseWatcher(job: job, dir: stepDir)

        let binaryPath = settings.mfluxIdeogram4BinaryPath()
        guard !binaryPath.isEmpty, FileManager.default.fileExists(atPath: binaryPath) else {
            finishJob(job, status: .failed("mflux-generate-ideogram4 not found. Check Settings → Advanced."), stepDir: stepDir)
            return
        }

        if job.quantize > 0 {
            let savedPath = ideogram4SavedPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
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

        let promptFileURL = writeCaptionTempFile(job: job)
        defer { promptFileURL.flatMap { try? FileManager.default.removeItem(at: $0) } }

        let runCtx = RunContext(
            seed: effectiveSeed, outputFile: outputTemplate,
            stepwiseDir: stepDir, promptFileURL: promptFileURL
        )
        let args = buildArgs(job: job, ctx: runCtx, settings: settings)
        job.log += "$ \(binaryPath) \(args.joined(separator: " "))\n\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.environment = settings.buildEnvironment()

        let stream = makeOutputStream(for: process)

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
        let expectedSteps = job.preset.stepCount

        for await chunk in stream {
            job.log = appendLog(chunk, to: job.log)
            if let progress = JobProgressParser.parseStep(from: job.log),
               progress.total == expectedSteps {
                if !seenFirstStep {
                    seenFirstStep = true
                    loadEndTime = Date()
                    let loadSecs = loadEndTime.map { $0.timeIntervalSince(jobStartTime) } ?? 0
                    let label = "▸ Encoding caption...  (loaded in \(formatDuration(loadSecs)))\n"
                    job.log = insertBeforeLastLine(job.log, text: label)
                }
                if !seenLastStep && progress.current == progress.total {
                    seenLastStep = true
                    denoiseEndTime = Date()
                    if !job.log.hasSuffix("\n") { job.log += "\n" }
                    job.log += "▸ Decoding image...\n"
                }
                job.isDenoising = true
                job.currentStep = progress.current
                job.totalSteps = progress.total
                if let elapsed = progress.elapsed, let remaining = progress.remaining {
                    job.stepTiming = "\(elapsed) elapsed · \(remaining) left"
                }
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
                for item in batchPaths
                    where FileManager.default.fileExists(atPath: item.path)
                    && isPNGComplete(at: item.path)
                    && !FileManager.default.fileExists(atPath: MetadataSidecar.sidecarURL(for: item.path).path) {
                    var meta = Ideogram4Metadata.from(job: job)
                    meta.seed = item.seed
                    MetadataSidecar.writeIdeogram4(meta, for: item.path)
                }
                job.log += "▸ Saved \(paths.count) images  (\(timing)total \(formatDuration(totalSecs)))\n"
                if job.completedSeedsInBatch == 0 { lastCompletedOutputPath = paths.first }
            } else {
                job.outputPath = outputTemplate
                job.log += "▸ Saved to: \(outputTemplate)  (\(timing)total \(formatDuration(totalSecs)))\n"
                job.thumbnailData = loadThumbnail(at: outputTemplate)
                MetadataSidecar.writeIdeogram4(Ideogram4Metadata.from(job: job), for: outputTemplate)
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

    // MARK: - Prompt file

    private func writeCaptionTempFile(job: Ideogram4Job) -> URL? {
        guard !job.usePlainPrompt, let json = job.caption.toJSON() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ideogram4-caption-\(job.id.uuidString).json")
        guard let data = json.data(using: .utf8) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - mflux-save for quantized weights

    private func runSave(job: Ideogram4Job, savePath: URL, settings: AppSettings) async -> SaveResult {
        // Ideogram 4 support is only in the uv-installed mflux (~/.local/bin); skip the configured dev dir.
        let saveBinary = BinaryDetector.detect("mflux-save")
        guard !saveBinary.isEmpty, FileManager.default.fileExists(atPath: saveBinary) else {
            job.log += "⚠️  mflux-save not found — falling back to in-memory quantization.\n"
            return .success
        }
        try? FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)
        job.log += "▸ Downloading and saving Q\(job.quantize) weights (one-time)...\n"
        job.statusLine = "Downloading model…"

        let args = ["--model", "ideogram4", "--quantize", "\(job.quantize)", "--path", savePath.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: saveBinary)
        process.arguments = args
        process.environment = settings.buildEnvironment()

        let stream = makeOutputStream(for: process)
        do { try process.run() } catch {
            self.currentProcess = nil
            job.log += "⚠️  mflux-save failed: \(error.localizedDescription)\n"
            return .failed
        }

        for await chunk in stream {
            job.log = appendLog(chunk, to: job.log)
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

    private func startStepwiseWatcher(job: Ideogram4Job, dir: URL) {
        stopStepwiseWatcher()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self, weak job] in
            guard let self, let job else { return }
            self.pollStepwise(job: job, dir: dir)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        stepwiseSource = source
        pollStepwise(job: job, dir: dir)
    }

    private func stopStepwiseWatcher() {
        stepwiseSource?.cancel()
        stepwiseSource = nil
    }

    private func pollStepwise(job: Ideogram4Job, dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
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

    private func startBatchPoller(job: Ideogram4Job, paths: [(seed: Int, path: String)]) {
        batchPollingTask?.cancel()
        batchPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var found = Set<String>()
            var perImageStartTime = job.startedAt ?? Date()
            while found.count < paths.count, !Task.isCancelled {
                for item in paths where !found.contains(item.path) {
                    guard FileManager.default.fileExists(atPath: item.path),
                          isPNGComplete(at: item.path) else { continue }
                    found.insert(item.path)
                    let imageGeneratedAt = Date()
                    var meta = Ideogram4Metadata.from(job: job)
                    meta.seed = item.seed
                    meta.startedAt = perImageStartTime
                    meta.generatedAt = imageGeneratedAt
                    MetadataSidecar.writeIdeogram4(meta, for: item.path)
                    perImageStartTime = imageGeneratedAt
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

    private func ideogram4SavedPath(quantize: Int, in cacheDir: URL) -> URL {
        cacheDir.appendingPathComponent("saved/ideogram4-q\(quantize)", isDirectory: true)
    }

    private func buildArgs(job: Ideogram4Job, ctx: RunContext, settings: AppSettings) -> [String] {
        var args: [String] = []

        let savedPath = ideogram4SavedPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
        if job.quantize > 0, FluxModelVariant.hasSavedWeights(at: savedPath) {
            args += ["--model", savedPath.path]
        } else if let override = settings.ideogram4ModelRepoOverride, !override.isEmpty {
            args += ["--model", override]
        } else {
            args += ["--model", "ideogram4"]
        }

        if job.usePlainPrompt || ctx.promptFileURL == nil {
            args += ["--prompt", job.usePlainPrompt ? job.plainPrompt : job.caption.highLevelDescription]
        } else if let fileURL = ctx.promptFileURL {
            args += ["--prompt-file", fileURL.path]
        }

        args += ["--preset", job.preset.rawValue]
        args += ["--width", "\(job.width)", "--height", "\(job.height)"]
        args += ["--output", ctx.outputFile]

        if job.seeds.isEmpty {
            args += ["--seed", "\(ctx.seed)"]
        } else {
            args += ["--seed"] + job.seeds.map { "\($0)" }
        }

        if job.quantize > 0, !FluxModelVariant.hasSavedWeights(at: savedPath),
           (settings.ideogram4ModelRepoOverride ?? "").isEmpty {
            args += ["--quantize", "\(job.quantize)"]
        }

        let enabledLoras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .ideogram4 }
        if !enabledLoras.isEmpty {
            args += ["--lora-paths"] + enabledLoras.map(\.path)
            args += ["--lora-scales"] + enabledLoras.map { String(format: "%.2f", $0.strength) }
        }

        if job.lowRam { args.append("--low-ram") }
        if settings.mlxCacheLimitGB > 0 {
            args += ["--mlx-cache-limit-gb", String(format: "%.1f", settings.mlxCacheLimitGB)]
        }
        if job.strictValidation { args.append("--strict-caption-validation") }
        if let cfgEnd = settings.ideogram4CfgEnd, cfgEnd < 1.0 {
            args += ["--cfg-end", String(format: "%.2f", cfgEnd)]
        }

        args += ["--stepwise-image-output-dir", ctx.stepwiseDir.path]

        return args
    }

    private func buildOutputPath(job: Ideogram4Job, settings: AppSettings, multiSeed: Bool = false) -> String? {
        let useBoard = !job.board.isEmpty && job.board != "Default"
        let dir = useBoard ? "\(settings.outputDir)/\(job.board)" : settings.outputDir
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dir), withIntermediateDirectories: true
            )
        } catch { return nil }
        let ts = Int(Date().timeIntervalSince1970)
        if multiSeed {
            return "\(dir)/ideogram4_\(ts).png"
        }
        let seedLabel = job.seed == -1 ? "rnd" : "\(job.seed)"
        return "\(dir)/ideogram4_\(ts)_\(seedLabel).png"
    }

    // MARK: - Finish / utilities

    private func finishJob(_ job: Ideogram4Job, status: JobStatus, stepDir: URL) {
        batchPollingTask?.cancel()
        batchPollingTask = nil
        stopStepwiseWatcher()
        try? FileManager.default.removeItem(at: stepDir)
        job.status = status
        job.completedAt = Date()
        job.latestStepwisePath = nil
        job.stepTiming = nil
        job.isDenoising = false
        if case .running = status { } else {
            activeJob = nil
            sessionCompleted += 1
        }
    }

    private func makeOutputStream(for process: Process) -> AsyncStream<String> {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.currentProcess = process

        return AsyncStream<String> { continuation in
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
    }

    private func isPNGComplete(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        guard size >= 12 else { return false }
        handle.seek(toFileOffset: size - 4)
        let tail = handle.readDataToEndOfFile()
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

    private func insertBeforeLastLine(_ log: String, text: String) -> String {
        if let lastNewline = log.lastIndex(of: "\n") {
            let split = log.index(after: lastNewline)
            let head = String(log[...lastNewline])
            let tail = String(log[split...])
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
