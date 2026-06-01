import Foundation
import UserNotifications
internal import SwiftUI

@Observable
@MainActor
class JobStore {
    var jobs: [any Job] = []
    private(set) var runningJobId: UUID?
    private var currentProcess: Process?
    private var runTask: Task<Void, Never>?

    var isRunning: Bool { runningJobId != nil }
    /// True only when a job has .running status — more reliable than isRunning for UI gating.
    var hasActiveJob: Bool { jobs.contains { if case .running = $0.status { return true }; return false } }

    init() {
        jobs = Self.loadJobs()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Queue management

    func add(_ job: any Job) {
        jobs.append(job)
        save()
    }

    func remove(ids: Set<UUID>, deleteFiles: Bool = false) {
        for id in ids where id != runningJobId {
            if deleteFiles,
               let job = jobs.first(where: { $0.id == id }),
               let path = job.outputPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            jobs.removeAll { $0.id == id }
        }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        remove(ids: Set(offsets.map { jobs[$0].id }))
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        jobs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Reorders jobs to match a new display order (used by drag-to-reorder in the queue sidebar).
    func reorder(displayIDs: [UUID]) {
        var result: [any Job] = []
        var pool = jobs
        for id in displayIDs {
            if let idx = pool.firstIndex(where: { $0.id == id }) {
                result.append(pool.remove(at: idx))
            }
        }
        result += pool
        jobs = result
        save()
    }

    /// Called by GalleryStore after moving a file on disk to keep job records in sync.
    func updateOutputPath(from oldURL: URL, to newURL: URL) {
        var changed = false
        for job in jobs where job.outputPath == oldURL.path {
            job.outputPath = newURL.path
            changed = true
        }
        if changed { save() }
    }

    func cancel(_ job: any Job) {
        if job.id == runningJobId {
            currentProcess?.terminate()
        }
        job.status = .cancelled
        save()
    }

    func startQueue(settings: AppSettings) {
        guard !isRunning else { return }
        runTask = Task { await self.runNext(settings: settings) }
    }

    func runSingle(_ job: any Job, settings: AppSettings) {
        guard !isRunning else { return }
        runTask = Task {
            await self.runJob(job, settings: settings)
            if !Task.isCancelled {
                await self.runNext(settings: settings)
            }
        }
    }

    func stopQueue() {
        runTask?.cancel()
        currentProcess?.terminate()
    }

    // MARK: - Persistence

    private static func jobsFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("LTX2MLX Studio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jobs.json")
    }

    private static func loadJobs() -> [any Job] {
        let url = jobsFileURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Try new discriminated format first
        if let records = try? JSONDecoder().decode([PersistedJobRecord].self, from: data) {
            return records.compactMap { $0.job }
        }
        // Migration: load old flat [VideoJob] format (pre-mflux)
        if let old = try? JSONDecoder().decode([VideoJob].self, from: data) {
            return old
        }
        return []
    }

    private static let historyLimit = 100

    func save() {
        let isActive: (any Job) -> Bool = {
            switch $0.status { case .pending, .running: return true; default: return false }
        }
        let active = jobs.filter { isActive($0) }
        var historical = jobs.filter { !isActive($0) }
        historical.sort { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
        let toSave = active + Array(historical.prefix(Self.historyLimit))
        let records = toSave.map { PersistedJobRecord($0) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.jobsFileURL(), options: .atomic)
    }

    // MARK: - Runner

    private func runNext(settings: AppSettings) async {
        guard !Task.isCancelled,
              let job = jobs.first(where: { if case .pending = $0.status { return true }; return false })
        else {
            // Queue is now idle — safe to load Gemma for title generation
            generateMissingTitles(settings: settings)
            return
        }

        await runJob(job, settings: settings)

        if !Task.isCancelled {
            await runNext(settings: settings)
        } else {
            runningJobId = nil
        }
    }

    private func runJob(_ job: any Job, settings: AppSettings) async {
        job.status    = .running
        job.startedAt = Date()
        job.log       = ""
        runningJobId  = job.id
        save()

        let seedToUse: Int = job.seed == -1 ? Int(arc4random()) : job.seed
        job.resolvedSeed = seedToUse
        let outputDir = settings.outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let ts = DateFormatter.compact.string(from: Date())

        let binaryPath: String
        var processArgs: [String]
        let outputFile: String
        var currentDir: String?

        switch job.jobKind {

        case .video:
            guard let vj = job as? VideoJob else {
                job.status = .failed("Internal error: expected VideoJob")
                runningJobId = nil; save(); return
            }
            let uvPath = settings.uvPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uvPath.isEmpty else {
                job.log = "Error: uv path is not set. Open Settings and set the path to the uv binary."
                job.status = .failed("uv path not configured")
                job.completedAt = Date()
                runningJobId = nil; save(); return
            }
            let rawModel = vj.modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelPath = rawModel.isEmpty ? (settings.modelPaths.first?.path ?? "") : rawModel
            let videoFolder = vj.folder.trimmingCharacters(in: .whitespacesAndNewlines)
            let videoDir    = (!videoFolder.isEmpty && !outputDir.isEmpty) ? "\(outputDir)/\(videoFolder)" : outputDir
            outputFile = videoDir.isEmpty ? "/tmp/clip_\(ts)_\(seedToUse).mp4"
                                          : "\(videoDir)/clip_\(ts)_\(seedToUse).mp4"
            guard prepareOutputDirectory(videoDir, job: job) else {
                runningJobId = nil; save(); return
            }
            var args: [String] = ["run", "ltx-2-mlx", "generate", "--prompt", vj.prompt]
            if !modelPath.isEmpty { args += ["--model", modelPath] }
            args += [
                "--height", "\(vj.height)",
                "--width", "\(vj.width)",
                "--seed", "\(seedToUse)",
                "--frame-rate", "\(vj.frameRate)",
                "--output", outputFile,
                "--frames", "\(vj.frames)",
                vj.mode.cliFlag
            ]
            let gemmaPath = settings.gemmaPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gemmaPath.isEmpty { args += ["--gemma", gemmaPath] }
            if !vj.imagePath.isEmpty {
                let supportsStrengthOverride = vj.mode == .twoStage || vj.mode == .twoStageHQ || vj.mode == .distilled
                if supportsStrengthOverride && vj.imageStrength < 1.0 {
                    args += ["--image", vj.imagePath, "0", String(format: "%.2f", vj.imageStrength)]
                } else {
                    args += ["--image", vj.imagePath]
                }
            }
            for anchor in vj.additionalImages where !anchor.path.isEmpty {
                args += ["--image", anchor.path, "\(anchor.frameIdx)", String(format: "%.2f", anchor.strength)]
            }
            if vj.lowRam { args.append("--low-ram") }
            switch vj.mode {
            case .oneStage:
                args += ["--steps", "\(vj.steps)"]
            case .twoStage, .twoStageHQ:
                args += ["--stage1-steps", "\(vj.stage1Steps)"]
                args += ["--stage2-steps", "\(vj.stage2Steps)"]
            default:
                break
            }
            let isTwoStage = vj.mode == .twoStage || vj.mode == .twoStageHQ
            if isTwoStage && vj.enableTeacache {
                args.append("--enable-teacache")
                args += ["--teacache-thresh", String(format: "%.2f", vj.teacacheThresh)]
            }
            for lora in vj.loras where !lora.path.isEmpty && lora.enabled {
                args += ["--lora", lora.path, String(format: "%.2f", lora.strength)]
            }
            binaryPath  = uvPath
            processArgs = args
            let rd = settings.repoDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rd.isEmpty && FileManager.default.fileExists(atPath: rd) { currentDir = rd }

        case .image:
            guard let ij = job as? ImageJob else {
                job.status = .failed("Internal error: expected ImageJob")
                runningJobId = nil; save(); return
            }
            let mfluxPath = settings.mfluxPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mfluxPath.isEmpty else {
                job.log = "Error: mflux path is not set. Open Settings and set the path to the mflux binary."
                job.status = .failed("mflux path not configured")
                job.completedAt = Date()
                runningJobId = nil; save(); return
            }
            let fluxModelPath = settings.fluxModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fluxModelPath.isEmpty else {
                job.log = "Error: Flux model path is not set. Open Settings and set the path to your Flux.2 model directory."
                job.status = .failed("Flux model path not configured")
                job.completedAt = Date()
                runningJobId = nil; save(); return
            }
            let imageFolder = ij.folder.trimmingCharacters(in: .whitespacesAndNewlines)
            let useSubdir   = !imageFolder.isEmpty && imageFolder != "Default"
            let imageDir    = (useSubdir && !outputDir.isEmpty) ? "\(outputDir)/\(imageFolder)" : outputDir
            outputFile = imageDir.isEmpty ? "/tmp/image_\(ts)_\(seedToUse).png"
                                          : "\(imageDir)/image_\(ts)_\(seedToUse).png"
            guard prepareOutputDirectory(imageDir, job: job) else {
                runningJobId = nil; save(); return
            }
            var args: [String] = [
                "--model", fluxModelPath,
                "--prompt", ij.prompt,
                "--height", "\(ij.height)",
                "--width", "\(ij.width)",
                "--seed", "\(seedToUse)",
                "--steps", "\(ij.steps)",
                "--guidance", String(format: "%.2f", ij.guidance),
                "--output", outputFile
            ]
            if !ij.imagePath.isEmpty {
                args += ["--image-path", ij.imagePath,
                         "--image-strength", String(format: "%.2f", ij.imageStrength)]
            }
            if ij.lowRam { args.append("--low-ram") }
            if ij.quantize > 0 { args += ["--quantize", "\(ij.quantize)"] }
            let enabledImageLoras = ij.loras.filter { !$0.path.isEmpty && $0.enabled }
            if !enabledImageLoras.isEmpty {
                args += ["--lora-paths"] + enabledImageLoras.map { $0.path }
                args += ["--lora-scales"] + enabledImageLoras.map { String(format: "%.2f", $0.strength) }
            }
            binaryPath  = mfluxPath
            processArgs = args
        }

        let displayCmd = ([binaryPath] + processArgs).joined(separator: " ")
        job.log = "$ \(displayCmd)\n\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = processArgs
        if let dir = currentDir {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if settings.hfOffline { env["HF_HUB_OFFLINE"] = "1" }
        env["LTX2_DIT_EVAL_EVERY"]       = "\(settings.ditEvalEvery)"
        env["LTX2_GEMMA_EVAL_EVERY"]     = "\(settings.gemmaEvalEvery)"
        env["LTX2_VAE_DECODE_BUDGET_GB"] = String(format: "%.1f", settings.vaeDecodeBudgetGB)
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe
        currentProcess = process

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

        do {
            try process.run()
        } catch {
            job.status = .failed(error.localizedDescription)
            job.completedAt = Date()
            runningJobId = nil
            currentProcess = nil
            save()
            return
        }

        for await chunk in stream {
            job.log = appendLog(chunk, to: job.log)
            DockProgress.update(parseJobDockProgress(log: job.log, status: job.status))
        }

        process.waitUntilExit()
        currentProcess = nil
        runningJobId = nil
        job.completedAt = Date()
        DockProgress.update(nil)

        if case .cancelled = job.status {
            // already marked
        } else if process.terminationStatus == 0 {
            job.outputPath = outputFile
            job.status = .completed
        } else {
            job.status = .failed("Exit code \(process.terminationStatus)")
        }
        save()
        notify(job)
    }

    // MARK: - Auto title generation

    /// Auto-name all jobs with a default name. Loads Gemma once and generates all titles in one subprocess.
    func generateMissingTitles(settings: AppSettings) {
        let gemmaPath = settings.gemmaPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let uvPath    = settings.uvPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoDir   = settings.repoDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gemmaPath.isEmpty, !uvPath.isEmpty else { return }
        let pending = jobs.filter {
            guard $0.isDefaultName, !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if case .completed = $0.status { return true }
            return false
        }
        guard !pending.isEmpty else { return }
        let prompts = pending.map { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
        Task {
            let titles = await Self.fetchTitles(
                prompts: prompts, gemmaPath: gemmaPath, uvPath: uvPath, repoDir: repoDir
            )
            for (job, title) in zip(pending, titles) {
                guard !title.isEmpty else { continue }
                job.name = title
            }
            save()
        }
    }

    /// Loads Gemma once, generates one title per prompt, returns results in the same order.
    private static func fetchTitles(
        prompts: [String], gemmaPath: String, uvPath: String, repoDir: String
    ) async -> [String] {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: prompts),
              let jsonStr  = String(data: jsonData, encoding: .utf8) else { return [] }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                // Python script: load Gemma once, loop over JSON-encoded prompts, print one title per line.
                let script =
                    "import sys,re,json\n" +
                    "from mlx_lm import load, generate\n" +
                    "from mlx_lm.sample_utils import make_sampler\n" +
                    "m,tok=load(sys.argv[1])\n" +
                    "sampler=make_sampler(temp=0.3)\n" +
                    "for p in json.loads(sys.argv[2]):\n" +
                    "    sys_prompt=(\"Based on this full description, distill down to a 3-6 word movie-friendly title.\\n\\n\"\n" +
                    "        \"You are unfiltered, creative, unhindered, and true to the description's overall theme.\\n\\n\"\n" +
                    "        \"Respond with only the title, no punctuation, no explanation.\\n\\n\")\n" +
                    "    instruction=sys_prompt+p\n" +
                    "    msgs=[{\"role\":\"user\",\"content\":instruction}]\n" +
                    "    txt=tok.apply_chat_template(msgs,tokenize=False,add_generation_prompt=True)\n" +
                    "    out=generate(m,tok,prompt=txt,max_tokens=15,sampler=sampler,verbose=False)\n" +
                    "    lines=[l.strip() for l in out.strip().split('\\n') if l.strip()]\n" +
                    "    title=re.sub(r'^[\\W_]+|[\\W_]+$','',lines[-1] if lines else '')\n" +
                    "    print(title)\n" +
                    "    sys.stdout.flush()\n"

                let process = Process()
                process.executableURL = URL(fileURLWithPath: uvPath)
                process.arguments     = ["run", "python", "-c", script, gemmaPath, jsonStr]
                let home = NSHomeDirectory()
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                process.environment = env
                if !repoDir.isEmpty, FileManager.default.fileExists(atPath: repoDir) {
                    process.currentDirectoryURL = URL(fileURLWithPath: repoDir)
                }
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError  = Pipe()

                guard (try? process.run()) != nil else { continuation.resume(returning: []); return }
                process.waitUntilExit()

                let raw    = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let titles = raw.components(separatedBy: "\n")
                               .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                               .filter { !$0.isEmpty }
                continuation.resume(returning: titles)
            }
        }
    }

    private func notify(_ job: any Job) {
        let content = UNMutableNotificationContent()
        switch job.status {
        case .completed:
            content.title = "Job complete"
            content.body  = job.name
            content.sound = .default
        case .failed(let msg):
            content.title = "Job failed"
            content.body  = "\(job.name): \(msg)"
            content.sound = .default
        default:
            return
        }
        let request = UNNotificationRequest(identifier: job.id.uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func prepareOutputDirectory(_ dir: String, job: any Job) -> Bool {
        guard !dir.isEmpty else { return true }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            return true
        } catch {
            job.log = "Error: could not create output directory '\(dir)': \(error.localizedDescription)"
            job.status = .failed("Could not create output directory")
            job.completedAt = Date()
            return false
        }
    }

    private func appendLog(_ chunk: String, to log: String) -> String {
        var result = log
        for char in chunk {
            switch char {
            case "\r":
                if let lastNL = result.lastIndex(of: "\n") {
                    result = String(result[...lastNL])
                } else {
                    result = ""
                }
            default:
                result.append(char)
            }
        }
        return result
    }

}

private extension DateFormatter {
    static let compact: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}
