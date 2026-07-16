// swiftlint:disable file_length
import Foundation

// MARK: - Protocols

/// The common surface of the per-family job classes (``FluxJob``, ``Ideogram4Job``,
/// ``Krea2Job``) that the shared ``JobRunner`` engine drives. Family-specific inputs
/// (prompt, preset, LoRAs, …) stay on the concrete class and are consumed by that
/// family's ``JobRunnerSpec``.
@MainActor
protocol GeneratedJob: AnyObject, Identifiable {
    var id: UUID { get }
    var status: JobStatus { get set }
    var log: String { get set }
    var currentStep: Int { get set }
    var totalSteps: Int { get set }
    var seed: Int { get }
    var seeds: [Int] { get }
    var resolvedSeed: Int? { get set }
    var quantize: Int { get }
    var board: String { get }
    var width: Int { get }
    var height: Int { get }
    var outputPath: String? { get set }
    var outputPaths: [String] { get set }
    var outputThumbnails: [Data] { get set }
    var thumbnailData: Data? { get set }
    var completedSeedsInBatch: Int { get set }
    var latestStepwisePath: String? { get set }
    var statusLine: String { get set }
    var stepTiming: String? { get set }
    var isDenoising: Bool { get set }
    var createdAt: Date { get }
    var startedAt: Date? { get set }
    var completedAt: Date? { get set }
}

/// The queue-store surface the runner drives (``JobStore``, ``Ideogram4JobStore``,
/// ``Krea2JobStore``).
@MainActor
protocol GenerationJobStore: AnyObject {
    associatedtype Job: GeneratedJob
    var pendingJobs: [Job] { get }
    var isRunning: Bool { get set }
    func expandBatchJob(_ batchJob: Job)
    func save()
}

/// Everything that differs between the model families. The shared ``JobRunner``
/// engine owns process lifecycle, log/progress streaming, batch polling and
/// reconciliation, timing capture, and queue draining; a spec supplies only the
/// family-specific pieces. Adding a family means writing a spec, not a runner.
@MainActor
protocol JobRunnerSpec {
    associatedtype Job: GeneratedJob
    associatedtype Store: GenerationJobStore where Store.Job == Job

    /// Cross-family run gate identity (see ``GenerationCoordinator``).
    static var family: ModelFamily { get }
    /// Subdirectory of the app cache dir that receives stepwise preview frames.
    static var stepwiseSubdir: String { get }
    /// Output filename stem: `{prefix}_{timestamp}_{seed}.png`.
    static var outputPrefix: String { get }
    /// Stage-marker text inserted into the log when the first denoise step appears.
    static var encodingLabel: String { get }

    /// CLI name shown in the "not found" error message.
    static func binaryName(job: Job) -> String
    static func binaryPath(job: Job, settings: AppSettings) -> String
    /// Where a one-time `mflux-save` quantization pass should write, or nil when the
    /// job loads weights directly (BF16, pre-quantized repo, or repo override).
    static func quantSaveDestination(job: Job, settings: AppSettings) -> URL?
    static func saveBinaryPath(settings: AppSettings) -> String
    /// `--model` argument for the `mflux-save` pass.
    static func saveModelID(job: Job) -> String
    /// Optional auxiliary prompt file written before launch and deleted after the run
    /// (Ideogram 4 structured captions). Default: none.
    static func makePromptFile(job: Job) -> URL?
    static func buildArgs(job: Job, ctx: JobRunContext, settings: AppSettings) -> [String]
    /// Whether a tqdm total belongs to this job's denoise loop (rejects other bars,
    /// e.g. weight-download progress).
    static func acceptsProgressTotal(_ total: Int, job: Job) -> Bool
    /// Model key for the learned-timing store (see ``TimingStore``).
    static func timingModelKey(job: Job) -> String
    static func timingLowRam(job: Job) -> Bool
    /// Writes the metadata sidecar for one finished image.
    static func writeMetadata(job: Job, seed: Int, startedAt: Date?, generatedAt: Date, path: String)
    /// Warm-driver request when the job is eligible for the persistent driver
    /// (see ``MfluxDriverController``), or nil to always use the CLI
    /// subprocess. Default: nil (family not supported by the driver).
    static func driverRequest(job: Job, ctx: JobRunContext, settings: AppSettings) -> DriverGenerateRequest?
}

extension JobRunnerSpec {
    static func makePromptFile(job _: Job) -> URL? {
        nil
    }

    static func driverRequest(job _: Job, ctx _: JobRunContext, settings _: AppSettings) -> DriverGenerateRequest? {
        nil
    }
}

/// Per-run values handed to ``JobRunnerSpec/buildArgs(job:ctx:settings:)``.
struct JobRunContext {
    let seed: Int
    let outputFile: String
    let stepwiseDir: URL
    /// Auxiliary prompt file from ``JobRunnerSpec/makePromptFile(job:)``, if any.
    let promptFile: URL?
}

// MARK: - JobRunner

/// Executes image generation jobs by driving a family's `mflux` CLI subprocess.
///
/// The engine picks pending jobs from the family's store one at a time, spawns the
/// process, streams its output into the job's log, updates progress as the run
/// advances, and reconciles batch output against the filesystem on completion.
/// Call ``runNext(in:settings:coordinator:timing:)`` after each job completes to
/// drive the queue forward. Cancel the active job via ``cancel()``.
///
/// One specialization exists per model family (``FluxJobRunner``,
/// ``Ideogram4JobRunner``, ``Krea2JobRunner``); the ``JobRunnerSpec`` supplies the
/// family-specific behavior.
@Observable
@MainActor
final class JobRunner<Spec: JobRunnerSpec> {
    typealias Job = Spec.Job

    private enum SaveResult { case success, cancelled, failed }

    /// Per-driver-run state shared between the event handler and finalization.
    /// A class so the escaping event closure can mutate it.
    private final class DriverRunProgress {
        var loadEnd: Date?
        var denoiseEnd: Date?
        var lastImageAt: Date?
        var landed: [(seed: Int, path: String)] = []
    }

    private static var cacheBase: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.mlxbits.image-studio/\(Spec.stepwiseSubdir)", isDirectory: true)
    }

    private(set) var activeJob: Job?
    private(set) var lastCompletedOutputPath: String?
    private(set) var batchImageLanded: Int = 0 // set per-seed; ContentView scans gallery on change
    private(set) var sessionCompleted: Int = 0
    private(set) var inSession: Bool = false
    /// Warm-model driver for this family, or nil to always use the CLI
    /// subprocess. Set at app startup (Flux only for now).
    var driver: MfluxDriverController?
    /// True while a cooperative cancel is pending, so Stop can offer to force
    /// one through. The driver is shared across families, but only the running
    /// one has `driverJobActive` set, so this stays scoped to this runner.
    var isStopping: Bool {
        driverJobActive && (driver?.isStopping ?? false)
    }

    private var runTask: Task<Void, Never>?
    private var currentProcess: Process?
    private var driverJobActive = false
    private let stepwiseWatcher = StepwiseWatcher()
    private var batchPollingTask: Task<Void, Never>?

    // MARK: - Public

    func runNext(in store: Spec.Store, settings: AppSettings, coordinator: GenerationCoordinator, timing: TimingStore) {
        guard runTask == nil else { return }
        // FIFO by submission time: the oldest pending job runs next, so a second
        // batch doesn't preempt the first (which would thrash the warm model —
        // e.g. reloading/re-fusing LoRAs at each batch boundary). The store
        // lists newest-first for display; execution order is independent of it.
        guard let job = store.pendingJobs.min(by: { $0.createdAt < $1.createdAt }) else {
            inSession = false
            coordinator.release(Spec.family)
            return
        }
        // Another family is mid-run: leave the job pending. ContentView pumps it once the
        // active family drains (so only one mflux process runs at a time — OOM guard).
        guard coordinator.tryAcquire(Spec.family) else { return }
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
        guard driverJobActive else {
            currentProcess?.terminate()
            return
        }
        // Cooperative while the driver is mid-denoise: it aborts at the next
        // step and the warm model survives. Everywhere else — and on a second
        // press — it falls back to a hard kill (see MfluxDriverController).
        if driver?.cancel() == true {
            activeJob?.statusLine = "Stopping…"
        }
    }

    // MARK: - Private execution

    // Intentionally long until the CLI subprocess is replaced with pure-Python
    // calls, at which point this method gets split up.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func run(_ job: Job, settings: AppSettings, timing: TimingStore) async {
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

        let binaryPath = Spec.binaryPath(job: job, settings: settings)
        guard !binaryPath.isEmpty, FileManager.default.fileExists(atPath: binaryPath) else {
            let message = "\(Spec.binaryName(job: job)) not found. Check Settings → Advanced."
            finishJob(job, status: .failed(message), stepDir: stepDir)
            return
        }

        // One-time mflux-save quantization pass, so every subsequent load skips
        // in-memory quantization. The spec decides whether the job needs it.
        if let savedPath = Spec.quantSaveDestination(job: job, settings: settings),
           !FluxModelVariant.hasSavedWeights(at: savedPath) {
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

        let promptFile = Spec.makePromptFile(job: job)
        defer { promptFile.flatMap { try? FileManager.default.removeItem(at: $0) } }

        let ctx = JobRunContext(
            seed: effectiveSeed, outputFile: outputTemplate,
            stepwiseDir: stepDir, promptFile: promptFile
        )

        // Warm-driver path: eligible jobs go to the persistent driver; any
        // startup failure falls through to the one-shot CLI below.
        if let driver, settings.keepModelWarm,
           let request = Spec.driverRequest(job: job, ctx: ctx, settings: settings) {
            if await driver.ensureRunning() {
                await runViaDriver(driver, request: request, job: job, stepDir: stepDir, timing: timing)
                return
            }
            job.log += "⚠️  Warm driver unavailable — falling back to one-shot CLI.\n"
        }

        let args = Spec.buildArgs(job: job, ctx: ctx, settings: settings)
        job.log += "$ \(binaryPath) \(args.joined(separator: " "))\n\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.environment = settings.buildEnvironment()

        currentProcess = process
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
            if let progress = JobProgressParser.parseStep(from: RunnerSupport.logTail(job.log)),
               Spec.acceptsProgressTotal(progress.total, job: job) {
                if !seenFirstStep {
                    seenFirstStep = true
                    loadEndTime = Date()
                    let loadSecs = loadEndTime.map { $0.timeIntervalSince(jobStartTime) } ?? 0
                    let label = "▸ \(Spec.encodingLabel)...  (loaded in \(RunnerSupport.formatDuration(loadSecs)))\n"
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

            // Feed the learned-timing model. Only record clean runs where we saw the full
            // denoise span; per-step cost is keyed by megapixels (see TimingStore).
            if let loadEnd = loadEndTime, let denoiseEnd = denoiseEndTime, job.totalSteps > 0 {
                timing.record(TimingStore.CompletedRun(
                    model: Spec.timingModelKey(job: job),
                    quantize: job.quantize, lowRam: Spec.timingLowRam(job: job),
                    loadSec: loadEnd.timeIntervalSince(jobStartTime),
                    denoiseSec: denoiseEnd.timeIntervalSince(loadEnd),
                    decodeSec: decodeSecs,
                    steps: job.totalSteps,
                    megapixels: Double(job.width * job.height) / 1_000_000
                ))
            }

            if isMultiSeed {
                // Reconcile against the disk (the poller may have been cancelled before
                // the last image) so the job only ever claims images that actually landed.
                let verified = RunnerSupport.reconcileBatch(batchPaths) { seed, path in
                    Spec.writeMetadata(
                        job: job, seed: seed,
                        startedAt: job.startedAt ?? Date(), generatedAt: Date(), path: path
                    )
                }
                let paths = verified.map(\.path)
                job.outputPaths = paths
                job.outputThumbnails = await RunnerSupport.makeThumbnails(for: paths)
                job.outputPath = paths.first
                job.thumbnailData = job.outputThumbnails.first
                job.completedSeedsInBatch = verified.count
                batchImageLanded = verified.count

                if verified.count == 1 { lastCompletedOutputPath = paths.first }
                if verified.count == batchPaths.count { lastCompletedOutputPath = paths.last }

                job.log += "▸ Saved \(verified.count) images  (\(timingLabel)total \(RunnerSupport.formatDuration(totalSecs)))\n"
            } else {
                job.outputPath = outputTemplate
                job.log += "▸ Saved to: \(outputTemplate)  (\(timingLabel)total \(RunnerSupport.formatDuration(totalSecs)))\n"
                job.thumbnailData = RunnerSupport.loadThumbnail(at: outputTemplate)
                Spec.writeMetadata(
                    job: job, seed: job.resolvedSeed ?? job.seed,
                    startedAt: job.startedAt, generatedAt: Date(), path: outputTemplate
                )
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

    // MARK: - Warm-driver execution

    private func runViaDriver(
        _ driver: MfluxDriverController,
        request: DriverGenerateRequest,
        job: Job,
        stepDir: URL,
        timing: TimingStore
    ) async {
        driverJobActive = true
        defer {
            driverJobActive = false
            driver.onLog = nil
        }

        let jobStart = Date()
        let progress = DriverRunProgress()
        let warmAtStart = driver.loadedFingerprint == request.fingerprint
        job.log += warmAtStart ? "▸ Model warm — \(Spec.encodingLabel)...\n" : "▸ Loading model...\n"
        job.statusLine = warmAtStart ? "\(Spec.encodingLabel)…" : "Loading model…"
        driver.onLog = { [weak job] chunk in
            guard let job else { return }
            job.log = RunnerSupport.appendLog(chunk, to: job.log)
            // Drive the visible step and ETA straight from tqdm — the exact line the CLI
            // prints — so the numbers match it precisely. The structured `progress` events
            // run slightly ahead of tqdm and carry no timing, so they are used only for
            // internal timing markers (see handleDriverEvent).
            guard let bar = JobProgressParser.parseStep(from: RunnerSupport.logTail(job.log)),
                  Spec.acceptsProgressTotal(bar.total, job: job) else { return }
            job.isDenoising = true
            job.currentStep = bar.current
            job.totalSteps = bar.total
            if let elapsed = bar.elapsed, let remaining = bar.remaining {
                job.stepTiming = "\(elapsed) elapsed · \(remaining) left"
            }
        }

        let result = await driver.run(request: request) { [weak self, weak job] event in
            guard let self, let job else { return }
            handleDriverEvent(event, job: job, progress: progress)
        }

        switch result {
        case .completed:
            await finalizeDriverCompletion(
                job: job, jobStart: jobStart, progress: progress, timing: timing, stepDir: stepDir
            )
        case .cancelled:
            finishJob(job, status: .cancelled, stepDir: stepDir)
        case let .failed(message):
            job.log += "⚠️  \(message)\n"
            finishJob(job, status: .failed(message), stepDir: stepDir)
        }
    }

    private func handleDriverEvent(_ event: DriverEvent, job: Job, progress: DriverRunProgress) {
        switch event.event {
        case "loading":
            job.statusLine = event.component == "text_encoder" ? "Loading text encoder…" : "Loading model…"
        case "loaded":
            progress.loadEnd = Date()
            let memory = event.memoryGb.map { String(format: " · %.1f GB", $0) } ?? ""
            let seconds = event.seconds.map { "in \(RunnerSupport.formatDuration($0))" } ?? ""
            job.log += "▸ Model loaded \(seconds)\(memory)\n▸ \(Spec.encodingLabel)...\n"
            job.statusLine = "\(Spec.encodingLabel)…"
        case "progress":
            // The visible step/ETA come from tqdm in the log (see onLog); this structured
            // event only marks the denoise end for the learned-timing model.
            guard let step = event.step, let total = event.total else { return }
            if step == total { progress.denoiseEnd = Date() }
        case "image":
            guard let seed = event.seed, let path = event.path else { return }
            let generatedAt = Date()
            Spec.writeMetadata(
                job: job, seed: seed,
                startedAt: progress.lastImageAt ?? job.startedAt,
                generatedAt: generatedAt, path: path
            )
            progress.lastImageAt = generatedAt
            progress.landed.append((seed: seed, path: path))
            job.completedSeedsInBatch = progress.landed.count
            if progress.landed.count == 1 { lastCompletedOutputPath = path }
            batchImageLanded += 1
        default:
            break
        }
    }

    private func finalizeDriverCompletion(
        job: Job,
        jobStart: Date,
        progress: DriverRunProgress,
        timing: TimingStore,
        stepDir: URL
    ) async {
        let totalSecs = Date().timeIntervalSince(jobStart)
        // Only cold-start driver runs feed the learned-timing model: warm runs
        // have no load phase and would drag the load estimate toward zero.
        if let loadEnd = progress.loadEnd, let denoiseEnd = progress.denoiseEnd, job.totalSteps > 0 {
            timing.record(TimingStore.CompletedRun(
                model: Spec.timingModelKey(job: job),
                quantize: job.quantize, lowRam: Spec.timingLowRam(job: job),
                loadSec: loadEnd.timeIntervalSince(jobStart),
                denoiseSec: denoiseEnd.timeIntervalSince(loadEnd),
                decodeSec: nil,
                steps: job.totalSteps,
                megapixels: Double(job.width * job.height) / 1_000_000
            ))
        }

        let paths = progress.landed.map(\.path)
        guard !paths.isEmpty else {
            finishJob(job, status: .failed("Driver reported success but no images landed"), stepDir: stepDir)
            return
        }
        if job.seeds.isEmpty {
            job.outputPath = paths[0]
            job.thumbnailData = RunnerSupport.loadThumbnail(at: paths[0])
            lastCompletedOutputPath = paths[0]
            job.log += "▸ Saved to: \(paths[0])  (total \(RunnerSupport.formatDuration(totalSecs)))\n"
        } else {
            job.outputPaths = paths
            job.outputThumbnails = await RunnerSupport.makeThumbnails(for: paths)
            job.outputPath = paths.first
            job.thumbnailData = job.outputThumbnails.first
            job.completedSeedsInBatch = paths.count
            batchImageLanded = paths.count
            lastCompletedOutputPath = paths.count == 1 ? paths.first : paths.last
            job.log += "▸ Saved \(paths.count) images  (total \(RunnerSupport.formatDuration(totalSecs)))\n"
        }
        finishJob(job, status: .completed, stepDir: stepDir)
    }

    // MARK: - mflux-save for quantized weights

    private func runSave(job: Job, savePath: URL, settings: AppSettings) async -> SaveResult {
        let saveBinary = Spec.saveBinaryPath(settings: settings)
        guard !saveBinary.isEmpty, FileManager.default.fileExists(atPath: saveBinary) else {
            job.log += "⚠️  mflux-save not found — falling back to in-memory quantization.\n"
            return .success // non-fatal: generate will quantize in-memory instead
        }
        try? FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)
        job.log += "▸ Downloading and saving Q\(job.quantize) weights (one-time)...\n"
        job.statusLine = "Downloading model…"

        let args = ["--model", Spec.saveModelID(job: job), "--quantize", "\(job.quantize)", "--path", savePath.path]
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
            // Surface the latest download/quantize line (skip the shell command echo).
            // Only the log tail — scanning the whole log per chunk is O(n²).
            if let last = RunnerSupport.logTail(job.log).components(separatedBy: "\n")
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

    private func startBatchPoller(job: Job, paths: [(seed: Int, path: String)]) {
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
                    Spec.writeMetadata(
                        job: job, seed: item.seed,
                        startedAt: perImageStartTime, generatedAt: imageGeneratedAt, path: item.path
                    )
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

    // MARK: - Finish / utilities

    private func buildOutputPath(job: Job, settings: AppSettings, multiSeed: Bool) -> String? {
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
            return "\(dir)/\(Spec.outputPrefix)_\(ts).png"
        }
        let seedLabel = job.seed == -1 ? "rnd" : "\(job.seed)"
        return "\(dir)/\(Spec.outputPrefix)_\(ts)_\(seedLabel).png"
    }

    private func finishJob(_ job: Job, status: JobStatus, stepDir: URL) {
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
