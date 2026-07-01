import Foundation

/// Executes Krea 2 Turbo generation jobs by driving the `mflux-generate-krea2` CLI
/// from the configured dev mflux install.
///
/// Weights come from `krea/Krea-2-Turbo`; for Q8/Q4 the runner first runs a one-time
/// `mflux-save` pass into the mflux cache dir (mirroring ``FluxJobRunner``), then loads
/// the saved dir on subsequent runs. BF16 loads the repo directly.
@Observable
@MainActor
final class Krea2JobRunner {
    // MARK: - Types

    private enum SaveResult { case success, cancelled, failed }

    private struct RunContext {
        let seed: Int
        let outputFile: String
        let stepwiseDir: URL
    }

    private static let cacheBase: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.mlxbits.image-studio/stepwise-krea2", isDirectory: true)
    }()

    private(set) var activeJob: Krea2Job?
    private(set) var lastCompletedOutputPath: String?
    private(set) var batchImageLanded: Int = 0
    private(set) var sessionCompleted: Int = 0
    private(set) var inSession: Bool = false
    private var runTask: Task<Void, Never>?
    private var currentProcess: Process?
    private let stepwiseWatcher = StepwiseWatcher()
    private var batchPollingTask: Task<Void, Never>?

    // MARK: - Public

    func runNext(in store: Krea2JobStore, settings: AppSettings, coordinator: GenerationCoordinator, timing: TimingStore) {
        guard runTask == nil else { return }
        guard let job = store.pendingJobs.first else {
            inSession = false
            coordinator.release(.krea2)
            return
        }
        // Another family is mid-run: leave the job pending. ContentView pumps it once the
        // active family drains (so only one mflux process runs at a time — OOM guard).
        guard coordinator.tryAcquire(.krea2) else { return }
        if !inSession {
            inSession = true
            sessionCompleted = 0
        }
        store.isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            await run(job, settings: settings, timing: timing)
            runTask = nil
            if !job.seeds.isEmpty, case .completed = job.status {
                store.expandBatchJob(job)
            }
            store.isRunning = false
            store.save()
            runNext(in: store, settings: settings, coordinator: coordinator, timing: timing)
        }
    }

    func cancel() {
        currentProcess?.terminate()
    }

    // MARK: - Private execution

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func run(_ job: Krea2Job, settings: AppSettings, timing: TimingStore) async {
        activeJob = job
        job.status = .running
        job.startedAt = Date()
        job.log = ""
        job.currentStep = 0

        let stepDir = Self.cacheBase.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: stepDir, withIntermediateDirectories: true)
        stepwiseWatcher.start(dir: stepDir) { [weak job] latest in
            guard let job, latest != job.latestStepwisePath else { return }
            job.latestStepwisePath = latest
        }

        let binaryPath = settings.mfluxKrea2BinaryPath()
        guard !binaryPath.isEmpty, FileManager.default.fileExists(atPath: binaryPath) else {
            finishJob(job, status: .failed("mflux-generate-krea2 not found. Check Settings → Advanced."), stepDir: stepDir)
            return
        }

        // Q8/Q4: one-time mflux-save quantization pass into the cache dir.
        if job.quantize > 0 {
            let savedPath = FluxModelVariant.krea2.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
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

        let runCtx = RunContext(seed: effectiveSeed, outputFile: outputTemplate, stepwiseDir: stepDir)
        let args = buildArgs(job: job, ctx: runCtx, settings: settings)
        job.log += "$ \(binaryPath) \(args.joined(separator: " "))\n\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.environment = settings.buildEnvironment()

        currentProcess = process
        let stream = RunnerSupport.outputStream(for: process)

        let batchPaths: [(seed: Int, path: String)] = isMultiSeed
            ? RunnerSupport.expandedPaths(from: outputTemplate, seeds: job.seeds)
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
            job.log = RunnerSupport.appendLog(chunk, to: job.log)
            // img2img runs fewer denoise steps than requested (the image-strength schedule
            // drops the leading steps), so the tqdm total can be < job.steps. Accept any
            // genuine tqdm bar up to the requested count rather than requiring exact equality,
            // otherwise the UI stays stuck on "Loading model…" for the whole img2img run.
            if let progress = JobProgressParser.parseStep(from: job.log),
               progress.total <= job.steps {
                if !seenFirstStep {
                    seenFirstStep = true
                    loadEndTime = Date()
                    let loadSecs = (loadEndTime ?? Date()).timeIntervalSince(jobStartTime)
                    let label = "▸ Generating...  (loaded in \(RunnerSupport.formatDuration(loadSecs)))\n"
                    job.log = RunnerSupport.insertBeforeLastLine(job.log, text: label)
                }
                if !seenLastStep, progress.current == progress.total {
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
        currentProcess = nil

        if process.terminationStatus == 0 {
            let totalSecs = Date().timeIntervalSince(jobStartTime)
            let decodeSecs = denoiseEndTime.map { Date().timeIntervalSince($0) }
            let timingLabel = decodeSecs.map { "decoded in \(RunnerSupport.formatDuration($0)) · " } ?? ""

            if let loadEnd = loadEndTime, let denoiseEnd = denoiseEndTime, job.totalSteps > 0 {
                timing.record(TimingStore.CompletedRun(
                    model: "krea2",
                    quantize: job.quantize, lowRam: false,
                    loadSec: loadEnd.timeIntervalSince(jobStartTime),
                    denoiseSec: denoiseEnd.timeIntervalSince(loadEnd),
                    decodeSec: decodeSecs,
                    steps: job.totalSteps,
                    megapixels: Double(job.width * job.height) / 1_000_000
                ))
            }

            if isMultiSeed {
                let paths = batchPaths.map(\.path)
                job.outputPaths = paths
                job.outputThumbnails = paths.map { RunnerSupport.loadThumbnail(at: $0) ?? Data() }
                job.outputPath = paths.first
                job.thumbnailData = job.outputThumbnails.first
                for item in batchPaths
                    where FileManager.default.fileExists(atPath: item.path)
                    && RunnerSupport.isPNGComplete(at: item.path)
                    && !FileManager.default.fileExists(atPath: MetadataSidecar.sidecarURL(for: item.path).path) {
                    var meta = Krea2Metadata.from(job: job)
                    meta.seed = item.seed
                    MetadataSidecar.writeKrea2(meta, for: item.path)
                }
                job.log += "▸ Saved \(paths.count) images  (\(timingLabel)total \(RunnerSupport.formatDuration(totalSecs)))\n"
                if job.completedSeedsInBatch == 0 { lastCompletedOutputPath = paths.first }
            } else {
                job.outputPath = outputTemplate
                job.log += "▸ Saved to: \(outputTemplate)  (\(timingLabel)total \(RunnerSupport.formatDuration(totalSecs)))\n"
                job.thumbnailData = RunnerSupport.loadThumbnail(at: outputTemplate)
                MetadataSidecar.writeKrea2(Krea2Metadata.from(job: job), for: outputTemplate)
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

    // MARK: - mflux-save for quantized weights

    private func runSave(job: Krea2Job, savePath: URL, settings: AppSettings) async -> SaveResult {
        let saveBinary = BinaryDetector.mfluxSave(in: settings.mfluxBinaryDir)
        guard !saveBinary.isEmpty, FileManager.default.fileExists(atPath: saveBinary) else {
            job.log += "⚠️  mflux-save not found — falling back to in-memory quantization.\n"
            return .success
        }
        try? FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)
        job.log += "▸ Downloading and saving Q\(job.quantize) weights (one-time)...\n"
        job.statusLine = "Downloading model…"

        let args = ["--model", FluxModelVariant.krea2.mfluxModelID, "--quantize", "\(job.quantize)", "--path", savePath.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: saveBinary)
        process.arguments = args
        process.environment = settings.buildEnvironment()

        currentProcess = process
        let stream = RunnerSupport.outputStream(for: process)
        do { try process.run() } catch {
            currentProcess = nil
            job.log += "⚠️  mflux-save failed: \(error.localizedDescription)\n"
            return .failed
        }

        for await chunk in stream {
            job.log = RunnerSupport.appendLog(chunk, to: job.log)
            if let last = job.log.components(separatedBy: "\n")
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("$") }) {
                job.statusLine = last
            }
        }
        process.waitUntilExit()
        currentProcess = nil

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

    // MARK: - Batch polling

    private func startBatchPoller(job: Krea2Job, paths: [(seed: Int, path: String)]) {
        batchPollingTask?.cancel()
        batchPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var found = Set<String>()
            var perImageStartTime = job.startedAt ?? Date()
            while found.count < paths.count, !Task.isCancelled {
                for item in paths where !found.contains(item.path) {
                    guard FileManager.default.fileExists(atPath: item.path),
                          RunnerSupport.isPNGComplete(at: item.path) else { continue }
                    found.insert(item.path)
                    let imageGeneratedAt = Date()
                    var meta = Krea2Metadata.from(job: job)
                    meta.seed = item.seed
                    meta.startedAt = perImageStartTime
                    meta.generatedAt = imageGeneratedAt
                    MetadataSidecar.writeKrea2(meta, for: item.path)
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

    private func buildArgs(job: Krea2Job, ctx: RunContext, settings: AppSettings) -> [String] {
        var args: [String] = []

        let savedPath = FluxModelVariant.krea2.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
        if job.quantize > 0, FluxModelVariant.hasSavedWeights(at: savedPath) {
            // Local mflux-saved weights: pass the dir directly, mflux detects stored_q.
            args += ["--model", savedPath.path]
        } else {
            args += ["--model", FluxModelVariant.krea2.mfluxModelID]
        }

        args += ["--prompt", job.prompt]
        // Negative prompt only takes effect with CFG on (guidance != 1).
        if job.guidance != 1.0, !job.negativePrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--negative-prompt", job.negativePrompt]
        }
        args += ["--width", "\(job.width)", "--height", "\(job.height)"]
        args += ["--steps", "\(job.steps)"]
        args += ["--guidance", String(format: "%.2f", job.guidance)]
        args += ["--output", ctx.outputFile]

        if job.seeds.isEmpty {
            args += ["--seed", "\(ctx.seed)"]
        } else {
            args += ["--seed"] + job.seeds.map { "\($0)" }
        }

        // No saved weights yet (mflux-save unavailable/failed): quantize in memory.
        if job.quantize > 0, !FluxModelVariant.hasSavedWeights(at: savedPath) {
            args += ["--quantize", "\(job.quantize)"]
        }

        // img2img: an init image seeds the latents; empty path = pure text-to-image.
        if !job.imagePath.isEmpty {
            args += [
                "--image-path", job.imagePath,
                "--image-strength", String(format: "%.2f", job.imageStrength),
            ]
        }

        let enabledLoras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .krea2 }
        if !enabledLoras.isEmpty {
            args += ["--lora-paths"] + enabledLoras.map(\.path)
            args += ["--lora-scales"] + enabledLoras.map { String(format: "%.2f", $0.strength) }
        }

        if settings.mlxCacheLimitGB > 0 {
            args += ["--mlx-cache-limit-gb", String(format: "%.1f", settings.mlxCacheLimitGB)]
        }

        args += ["--stepwise-image-output-dir", ctx.stepwiseDir.path]

        return args
    }

    private func buildOutputPath(job: Krea2Job, settings: AppSettings, multiSeed: Bool = false) -> String? {
        let useBoard = !job.board.isEmpty && job.board != "Default"
        let dir = useBoard ? "\(settings.outputDir)/\(job.board)" : settings.outputDir
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dir), withIntermediateDirectories: true
            )
        } catch { return nil }
        let ts = Int(Date().timeIntervalSince1970)
        if multiSeed {
            return "\(dir)/krea2_\(ts).png"
        }
        let seedLabel = job.seed == -1 ? "rnd" : "\(job.seed)"
        return "\(dir)/krea2_\(ts)_\(seedLabel).png"
    }

    // MARK: - Finish / utilities

    private func finishJob(_ job: Krea2Job, status: JobStatus, stepDir: URL) {
        batchPollingTask?.cancel()
        batchPollingTask = nil
        stepwiseWatcher.stop()
        try? FileManager.default.removeItem(at: stepDir)
        job.status = status
        job.completedAt = Date()
        job.latestStepwisePath = nil
        job.stepTiming = nil
        job.isDenoising = false
        if case .running = status {} else {
            activeJob = nil
            sessionCompleted += 1
        }
    }
}
