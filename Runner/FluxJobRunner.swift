import Foundation
import AppKit

@Observable
@MainActor
final class FluxJobRunner {
    private(set) var activeJob: FluxJob?
    private(set) var lastCompletedOutputPath: String? = nil
    private(set) var sessionCompleted: Int = 0
    private(set) var sessionTotal: Int = 0
    private var inSession: Bool = false
    private var runTask: Task<Void, Never>?
    private var currentProcess: Process?
    private var stepwiseTimer: Timer?

    private static let cacheBase: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
            sessionTotal = store.pendingJobs.count
        }
        store.isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(job, settings: settings)
            self.runTask = nil
            store.isRunning = false
            store.save()
            self.runNext(in: store, settings: settings)
        }
    }

    func cancel() {
        currentProcess?.terminate()
    }

    // MARK: - Private execution

    private func run(_ job: FluxJob, settings: AppSettings) async {
        activeJob = job
        job.status = .running
        job.startedAt = Date()
        job.log = ""
        job.currentStep = 0

        let stepDir = Self.cacheBase.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: stepDir, withIntermediateDirectories: true)
        startStepwiseWatcher(job: job, dir: stepDir)

        let binaryPath = settings.mfluxBinaryPath()
        guard !binaryPath.isEmpty, FileManager.default.fileExists(atPath: binaryPath) else {
            finishJob(job, status: .failed("mflux binary not found. Check Settings → Advanced."), stepDir: stepDir)
            return
        }

        // For quantized non-custom models, ensure a local saved copy exists so every subsequent
        // load skips in-memory quantization. The mlx-community pre-quantized repos are preferred
        // when known; otherwise we run mflux-save once to produce a local saved copy.
        if job.quantize > 0, job.model != .custom,
           job.model.preQuantizedRepoID(quantize: job.quantize) == nil {
            let savedPath = job.model.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
            if !FluxModelVariant.hasSavedWeights(at: savedPath) {
                let saved = await runSave(job: job, savePath: savedPath, settings: settings)
                if !saved {
                    finishJob(job, status: .failed("Failed to save quantized model weights"), stepDir: stepDir)
                    return
                }
            }
        }

        settings.ensureOutputDirExists()
        guard let outputFile = buildOutputPath(job: job, settings: settings) else {
            finishJob(job, status: .failed("Could not create output directory"), stepDir: stepDir)
            return
        }

        let effectiveSeed = job.seed >= 0 ? job.seed : Int(UInt32.random(in: 0 ..< UInt32.max))
        job.resolvedSeed = effectiveSeed

        let args = buildArgs(job: job, seed: effectiveSeed, outputFile: outputFile, stepwiseDir: stepDir, settings: settings)
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
                if data.isEmpty { continuation.finish() }
                else if let text = String(data: data, encoding: .utf8) { continuation.yield(text) }
            }
            process.terminationHandler = { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish()
                }
            }
        }

        let jobStartTime = Date()
        job.log += "▸ Loading model...\n"

        do { try process.run() } catch {
            finishJob(job, status: .failed(error.localizedDescription), stepDir: stepDir)
            return
        }

        var seenFirstStep = false
        var seenLastStep = false
        var loadEndTime: Date? = nil
        var denoiseEndTime: Date? = nil

        for await chunk in stream {
            job.log = appendLog(chunk, to: job.log)
            if let progress = JobProgressParser.parseStep(from: job.log),
               progress.total == job.steps {

                if !seenFirstStep {
                    seenFirstStep = true
                    loadEndTime = Date()
                    let loadSecs = loadEndTime!.timeIntervalSince(jobStartTime)
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
            job.outputPath = outputFile
            let totalSecs = Date().timeIntervalSince(jobStartTime)
            let decodeSecs = denoiseEndTime.map { Date().timeIntervalSince($0) }
            let timing = decodeSecs.map { "decoded in \(formatDuration($0)) · " } ?? ""
            job.log += "▸ Saved to: \(outputFile)  (\(timing)total \(formatDuration(totalSecs)))\n"
            job.thumbnailData = loadThumbnail(at: outputFile)
            MetadataSidecar.write(GenerationMetadata.from(job: job), for: outputFile)
            lastCompletedOutputPath = outputFile
            finishJob(job, status: .completed, stepDir: stepDir)
        } else if process.terminationReason == .uncaughtSignal {
            finishJob(job, status: .cancelled, stepDir: stepDir)
        } else {
            let lastLine = job.log.components(separatedBy: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Unknown error"
            finishJob(job, status: .failed(lastLine), stepDir: stepDir)
        }
    }

    private func finishJob(_ job: FluxJob, status: JobStatus, stepDir: URL) {
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

    private func runSave(job: FluxJob, savePath: URL, settings: AppSettings) async -> Bool {
        let saveBinary = BinaryDetector.mfluxSave(in: settings.mfluxBinaryDir)
        guard !saveBinary.isEmpty, FileManager.default.fileExists(atPath: saveBinary) else {
            job.log += "⚠️  mflux-save not found — falling back to in-memory quantization.\n"
            return true  // non-fatal: generate will quantize in-memory instead
        }
        try? FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)
        job.log += "▸ Saving Q\(job.quantize) weights (one-time, ~\(job.quantize == 8 ? "17" : "9") GB)...\n"

        let args = ["--model", job.model.mfluxModelID, "--quantize", "\(job.quantize)", "--path", savePath.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: saveBinary)
        process.arguments = args
        process.environment = settings.buildEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let stream = AsyncStream<String> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { continuation.finish() }
                else if let text = String(data: data, encoding: .utf8) { continuation.yield(text) }
            }
            process.terminationHandler = { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish()
                }
            }
        }

        do { try process.run() } catch {
            job.log += "⚠️  mflux-save failed: \(error.localizedDescription)\n"
            return false
        }

        for await chunk in stream {
            job.log = appendLog(chunk, to: job.log)
        }
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            job.log += "▸ Weights saved.\n"
            return true
        } else {
            job.log += "⚠️  mflux-save exited with status \(process.terminationStatus).\n"
            // Clean up partial save so we retry next time rather than loading corrupt weights
            try? FileManager.default.removeItem(at: savePath)
            return false
        }
    }

    // MARK: - Stepwise watcher

    private func startStepwiseWatcher(job: FluxJob, dir: URL) {
        stopStepwiseWatcher()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak job] _ in
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
            .filter { $0.pathExtension.lowercased() == "png" }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return a < b
            }
        if latest?.path != job.latestStepwisePath {
            job.latestStepwisePath = latest?.path
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

        let supportsNeg = job.model == .custom || !job.model.isDistilled
        if supportsNeg, !job.negativePrompt.isEmpty {
            args += ["--negative-prompt", job.negativePrompt]
        }

        args += [
            "--width",    "\(job.width)",
            "--height",   "\(job.height)",
            "--steps",    "\(job.steps)",
            "--guidance", String(format: "%.2f", job.guidance),
            "--output",   outputFile,
        ]

        args += ["--seed", "\(seed)"]

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

        if !job.imagePath.isEmpty {
            args += ["--image-path", job.imagePath,
                     "--image-strength", String(format: "%.2f", job.imageStrength)]
        }

        let enabledLoras = job.loras.filter { $0.enabled && $0.isValid }
        if !enabledLoras.isEmpty {
            args += ["--lora-paths"] + enabledLoras.map(\.path)
            args += ["--lora-scales"] + enabledLoras.map { String(format: "%.2f", $0.strength) }
        }

        args += ["--stepwise-image-output-dir", stepwiseDir.path]

        return args
    }

    private func buildOutputPath(job: FluxJob, settings: AppSettings) -> String? {
        let useBoard = !job.board.isEmpty && job.board != "Default"
        let dir = useBoard ? "\(settings.outputDir)/\(job.board)" : settings.outputDir
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        } catch { return nil }
        let ts = Int(Date().timeIntervalSince1970)
        let seed = job.seed == -1 ? "rnd" : "\(job.seed)"
        return "\(dir)/image_\(ts)_\(seed).png"
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
