import Foundation
import AppKit

@Observable
@MainActor
final class FluxJobRunner {
    private(set) var activeJob: FluxJob?
    private var runTask: Task<Void, Never>?
    private var currentProcess: Process?
    private var stepwiseTimer: Timer?

    private static let cacheBase: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MLXBits Image Studio/stepwise", isDirectory: true)
    }()

    // MARK: - Public

    func runNext(in store: JobStore, settings: AppSettings) {
        guard runTask == nil, let job = store.pendingJobs.first else { return }
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

        settings.ensureOutputDirExists()
        guard let outputFile = buildOutputPath(job: job, settings: settings) else {
            finishJob(job, status: .failed("Could not create output directory"), stepDir: stepDir)
            return
        }

        let args = buildArgs(job: job, outputFile: outputFile, stepwiseDir: stepDir, settings: settings)
        job.log = "$ \(binaryPath) \(args.joined(separator: " "))\n\n"

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

        do { try process.run() } catch {
            finishJob(job, status: .failed(error.localizedDescription), stepDir: stepDir)
            return
        }

        for await chunk in stream {
            job.log = appendLog(chunk, to: job.log)
            if let progress = JobProgressParser.parseStep(from: job.log) {
                job.currentStep = progress.current
                job.totalSteps  = progress.total
            }
        }

        process.waitUntilExit()
        self.currentProcess = nil

        if process.terminationStatus == 0 {
            job.outputPath = outputFile
            if let seed = JobProgressParser.parseSeed(from: job.log) { job.resolvedSeed = seed }
            job.thumbnailData = loadThumbnail(at: outputFile)
            MetadataSidecar.write(GenerationMetadata.from(job: job), for: outputFile)
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
        if case .running = status { } else { activeJob = nil }
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
        job: FluxJob, outputFile: String, stepwiseDir: URL, settings: AppSettings
    ) -> [String] {
        var args: [String] = []

        if job.model == .custom {
            args += ["--model", job.customModelRepo, "--base-model", job.customBaseModel.mfluxModelID]
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
            "--seed",     "\(job.seed)",
            "--steps",    "\(job.steps)",
            "--guidance", String(format: "%.2f", job.guidance),
            "--output",   outputFile,
        ]

        if job.quantize > 0 { args += ["--quantize", "\(job.quantize)"] }
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
        let size = CGSize(width: 200, height: 200)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: size),
                 from: NSRect(origin: .zero, size: img.size),
                 operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        guard let tiff = thumb.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
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
