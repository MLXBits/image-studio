import Foundation

/// Executes Ideogram 4 generation jobs by driving the `mflux-generate-ideogram4` CLI.
/// The shared ``JobRunner`` engine owns the process lifecycle; this spec supplies the
/// Ideogram-specific behavior (structured caption prompt files, preset step counts).
typealias Ideogram4JobRunner = JobRunner<Ideogram4RunnerSpec>

extension Ideogram4Job: GeneratedJob {}
extension Ideogram4JobStore: GenerationJobStore {}

enum Ideogram4RunnerSpec: JobRunnerSpec {
    typealias Job = Ideogram4Job
    typealias Store = Ideogram4JobStore

    static let family: ModelFamily = .ideogram4
    static let stepwiseSubdir = "stepwise-ideogram4"
    static let outputPrefix = "ideogram4"
    static let encodingLabel = "Encoding caption"

    static func binaryName(job _: Ideogram4Job) -> String {
        "mflux-generate-ideogram4"
    }

    static func binaryPath(job _: Ideogram4Job, settings: AppSettings) -> String {
        settings.mfluxIdeogram4BinaryPath()
    }

    /// Q8/Q4 load pre-quantized MLX weights directly from the published repo —
    /// no one-time mflux-save quantization pass needed for them.
    static func quantSaveDestination(job: Ideogram4Job, settings: AppSettings) -> URL? {
        guard job.quantize > 0,
              FluxModelVariant.ideogram4.preQuantizedRepoID(quantize: job.quantize) == nil else { return nil }
        return FluxModelVariant.ideogram4.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
    }

    /// Ideogram 4 support is only in the uv-installed mflux (~/.local/bin); skip the
    /// configured dev dir.
    static func saveBinaryPath(settings _: AppSettings) -> String {
        BinaryDetector.detect("mflux-save")
    }

    static func saveModelID(job _: Ideogram4Job) -> String {
        "ideogram4"
    }

    /// Structured captions travel as a JSON prompt file; plain prompts go inline.
    static func makePromptFile(job: Ideogram4Job) -> URL? {
        guard !job.usePlainPrompt, let json = job.caption.toJSON() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ideogram4-caption-\(job.id.uuidString).json")
        guard let data = json.data(using: .utf8) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    static func acceptsProgressTotal(_ total: Int, job: Ideogram4Job) -> Bool {
        total == job.preset.stepCount
    }

    static func timingModelKey(job _: Ideogram4Job) -> String {
        "ideogram4"
    }

    static func timingLowRam(job: Ideogram4Job) -> Bool {
        job.lowRam
    }

    static func writeMetadata(job: Ideogram4Job, seed: Int, startedAt: Date?, generatedAt: Date, path: String) {
        var meta = Ideogram4Metadata.from(job: job)
        meta.seed = seed
        meta.startedAt = startedAt
        meta.generatedAt = generatedAt
        MetadataSidecar.writeIdeogram4(meta, for: path)
    }

    static func buildArgs(job: Ideogram4Job, ctx: JobRunContext, settings: AppSettings) -> [String] {
        var args: [String] = []

        let override = (settings.ideogram4ModelRepoOverride ?? "").isEmpty
            ? nil
            : settings.ideogram4ModelRepoOverride
        let preQuantizedRepo = override == nil && job.quantize > 0
            ? FluxModelVariant.ideogram4.preQuantizedRepoID(quantize: job.quantize)
            : nil
        let savedPath = FluxModelVariant.ideogram4.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
        if let override {
            // Settings model-source override wins outright — it names a specific
            // repo/path, so the precision selector is inert (UI shows "Override").
            args += ["--model", override]
        } else if let preQuantizedRepo {
            // Pre-quantized MLX weights — passed directly, no --quantize flag.
            args += ["--model", preQuantizedRepo]
        } else if job.quantize > 0, FluxModelVariant.hasSavedWeights(at: savedPath) {
            args += ["--model", savedPath.path]
        } else {
            args += ["--model", "ideogram4"]
        }

        if job.usePlainPrompt || ctx.promptFile == nil {
            args += ["--prompt", job.usePlainPrompt ? job.plainPrompt : job.caption.highLevelDescription]
        } else if let promptFile = ctx.promptFile {
            args += ["--prompt-file", promptFile.path]
        }

        args += ["--preset", job.preset.rawValue]
        args += ["--width", "\(job.width)", "--height", "\(job.height)"]
        args += ["--output", ctx.outputFile]

        if job.seeds.isEmpty {
            args += ["--seed", "\(ctx.seed)"]
        } else {
            args += ["--seed"] + job.seeds.map { "\($0)" }
        }

        if override == nil, preQuantizedRepo == nil, job.quantize > 0,
           !FluxModelVariant.hasSavedWeights(at: savedPath) {
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
}
