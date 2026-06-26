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
    // MARK: - One-time quantized model save

    private enum SaveResult { case success, cancelled, failed }

    private static let cacheBase: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.mlxbits.image-studio/stepwise", isDirectory: true)
    }()

    private(set) var activeJob: FluxJob?
    private(set) var lastCompletedOutputPath: String?
    private(set) var batchImageLanded: Int = 0 // incremented per-seed; ContentView scans gallery on change
    private(set) var sessionCompleted: Int = 0
    private(set) var inSession: Bool = false
    private var runTask: Task<Void, Never>?
    private var currentProcess: Process?
    private let stepwiseWatcher = StepwiseWatcher()
    private var batchPollingTask: Task<Void, Never>?

    // MARK: - Public

    func runNext(in store: JobStore, settings: AppSettings, coordinator: GenerationCoordinator, timing: TimingStore) {
        guard runTask == nil else { return }
        guard let job = store.pendingJobs.first else {
            inSession = false
            coordinator.release(.flux)
            return
        }
        // Another family is mid-run: leave the job pending. ContentView pumps it once the
        // active family drains (so only one mflux process runs at a time — OOM guard).
        guard coordinator.tryAcquire(.flux) else { return }
        if !inSession {
            inSession = true
            sessionCompleted = 0
        }
        store.isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(job, settings: settings, timing: timing)
            self.runTask = nil
            if !job.seeds.isEmpty, case .completed = job.status {
                store.expandBatchJob(job)
            }
            store.isRunning = false
            store.save()
            self.runNext(in: store, settings: settings, coordinator: coordinator, timing: timing)
        }
    }

    func cancel() {
        currentProcess?.terminate()
    }

    // MARK: - Private execution

    // Intentionally long until the CLI subprocess is replaced with pure-Python
    // calls, at which point this method gets split up.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func run(_ job: FluxJob, settings: AppSettings, timing: TimingStore) async {
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

        let binaryPath = job.isEditMode ? settings.mfluxEditBinaryPath() : settings.mfluxBinaryPath()
        guard !binaryPath.isEmpty, FileManager.default.fileExists(atPath: binaryPath) else {
            let name = job.isEditMode ? "mflux-generate-flux2-edit" : "mflux-generate-flux2"
            finishJob(job, status: .failed("\(name) not found. Check Settings → Advanced."), stepDir: stepDir)
            return
        }

        // For quantized non-custom models, ensure a local saved copy exists so every subsequent
        // load skips in-memory quantization.
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

        self.currentProcess = process
        let stream = RunnerSupport.outputStream(for: process)

        // Pre-compute expected output paths for multi-seed so we can poll as each lands.
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
            // genuine tqdm bar up to the requested count rather than requiring exact equality.
            if let progress = JobProgressParser.parseStep(from: job.log),
               progress.total <= job.steps {
                if !seenFirstStep {
                    seenFirstStep = true
                    loadEndTime = Date()
                    let loadSecs = loadEndTime.map { $0.timeIntervalSince(jobStartTime) } ?? 0
                    let label = "▸ Encoding prompt...  (loaded in \(RunnerSupport.formatDuration(loadSecs)))\n"
                    job.log = RunnerSupport.insertBeforeLastLine(job.log, text: label)
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
            let timingLabel = decodeSecs.map { "decoded in \(RunnerSupport.formatDuration($0)) · " } ?? ""

            // Feed the learned-timing model. Only record clean runs where we saw the full
            // denoise span; per-step cost is keyed by megapixels (see TimingStore).
            if let loadEnd = loadEndTime, let denoiseEnd = denoiseEndTime, job.totalSteps > 0 {
                timing.record(TimingStore.CompletedRun(
                    model: TimingStore.fluxModelKey(job.model, customRepo: job.customModelRepo),
                    quantize: job.quantize, lowRam: job.lowRam,
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

                // --- RECONCILIATION BLOCK ---
                // The batchPoller is asynchronous and might be cancelled before it finds the last image.
                // We perform a final, authoritative scan of the disk to determine the true count.
                var verifiedPathsCount = 0
                for item in batchPaths {
                    if FileManager.default.fileExists(atPath: item.path), RunnerSupport.isPNGComplete(at: item.path) {
                        verifiedPathsCount += 1

                        // Ensure metadata sidecar exists for this confirmed image
                        if !FileManager.default.fileExists(atPath: MetadataSidecar.sidecarURL(for: item.path).path) {
                            var meta = GenerationMetadata.from(job: job)
                            meta.seed = item.seed
                            meta.startedAt = job.startedAt ?? Date()
                            meta.generatedAt = Date()
                            MetadataSidecar.write(meta, for: item.path)
                        }
                    }
                }

                // Sync the job and runner state with the actual filesystem state
                job.completedSeedsInBatch = verifiedPathsCount
                self.batchImageLanded = verifiedPathsCount

                if verifiedPathsCount == 1 { lastCompletedOutputPath = paths.first }
                if verifiedPathsCount == paths.count { lastCompletedOutputPath = paths.last }
                // ----------------------------

                job.log += "▸ Saved \(verifiedPathsCount) images  (\(timingLabel)total \(RunnerSupport.formatDuration(totalSecs)))\n"
            } else {
                job.outputPath = outputTemplate
                job.log += "▸ Saved to: \(outputTemplate)  (\(timingLabel)total \(RunnerSupport.formatDuration(totalSecs)))\n"
                job.thumbnailData = RunnerSupport.loadThumbnail(at: outputTemplate)
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
        stepwiseWatcher.stop()
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

    private func runSave(job: FluxJob, savePath: URL, settings: AppSettings) async -> SaveResult {
        let saveBinary = BinaryDetector.mfluxSave(in: settings.mfluxBinaryDir)
        guard !saveBinary.isEmpty, FileManager.default.fileExists(atPath: saveBinary) else {
            job.log += "⚠️  mflux-save not found — falling back to in-memory quantization.\n"
            return .success // non-fatal: generate will quantize in-memory instead
        }
        try? FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)
        job.log += "▸ Downloading and saving Q\(job.quantize) weights (one-time)...\n"
        job.statusLine = "Downloading model…"

        let args = ["--model", job.model.mfluxModelID, "--quantize", "\(job.quantize)", "--path", savePath.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: saveBinary)
        process.arguments = args
        process.environment = settings.buildEnvironment()

        self.currentProcess = process
        let stream = RunnerSupport.outputStream(for: process)

        do { try process.run() } catch {
            self.currentProcess = nil
            job.log += "⚠️  mflux-save failed: \(error.localizedDescription)\n"
            return .failed
        }

        for await chunk in stream {
            job.log = RunnerSupport.appendLog(chunk, to: job.log)
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

    // MARK: - Batch polling

    private func startBatchPoller(job: FluxJob, paths: [(seed: Int, path: String)]) {
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
                    var meta = GenerationMetadata.from(job: job)
                    meta.seed = item.seed
                    meta.startedAt = perImageStartTime
                    meta.generatedAt = imageGeneratedAt
                    MetadataSidecar.write(meta, for: item.path)
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

        let enabledLoras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .flux }
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
                at: URL(fileURLWithPath: dir), withIntermediateDirectories: true
            )
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
}
