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
    /// no one-time mflux-save quantization pass needed for them, nor for a
    /// custom/overridden source that names specific weights.
    static func quantSaveDestination(job: Ideogram4Job, settings: AppSettings) -> URL? {
        guard job.quantize > 0,
              modelSourceOverride(job: job, settings: settings) == nil,
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

    static func timingModelKey(job: Ideogram4Job) -> String {
        TimingStore.modelKey("ideogram4", customRepo: job.customModelRepo)
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

    /// A repo ID or path that replaces the stock Ideogram 4 model source: the
    /// picker's `Custom…` entry first, then the Settings → Models override. Both
    /// name a specific set of weights, so neither takes a `--quantize` pass — the
    /// UI shows "Override" and disables the precision selector.
    private static func modelSourceOverride(job: Ideogram4Job, settings: AppSettings) -> String? {
        let custom = job.customModelRepo.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            return custom
        }
        let override = (settings.ideogram4ModelRepoOverride ?? "").trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? nil : override
    }

    /// Resolves the `--model` value and the `--quantize` level that goes with it.
    /// Precedence: custom repo → Settings override → pre-quantized MLX repo →
    /// local mflux-saved weights → the built-in `ideogram4` name.
    private static func resolveModel(job: Ideogram4Job, settings: AppSettings) -> (model: String, quantize: Int?) {
        if let source = modelSourceOverride(job: job, settings: settings) {
            return (source, nil)
        }
        guard job.quantize > 0 else { return ("ideogram4", nil) }
        if let preQuantizedRepo = FluxModelVariant.ideogram4.preQuantizedRepoID(quantize: job.quantize) {
            // Pre-quantized MLX weights — passed directly, no --quantize flag.
            return (preQuantizedRepo, nil)
        }
        let savedPath = FluxModelVariant.ideogram4.savedModelPath(
            quantize: job.quantize, in: settings.effectiveMfluxCacheDir
        )
        if FluxModelVariant.hasSavedWeights(at: savedPath) {
            return (savedPath.path, nil)
        }
        return ("ideogram4", job.quantize)
    }

    /// Driver eligibility + request. Low-RAM jobs stream blocks from disk and
    /// stay on the one-shot CLI. The caption travels inline as its JSON string
    /// (no prompt file needed on this path). Note the driver never evicts the
    /// Ideogram text encoder — its config is weight-layout-dependent — but the
    /// model's native prompt cache still skips re-encodes of the same caption.
    static func driverRequest(job: Ideogram4Job, ctx: JobRunContext, settings: AppSettings) -> DriverGenerateRequest? {
        guard !job.lowRam else { return nil }

        let (model, quantizeArg) = resolveModel(job: job, settings: settings)

        let prompt = job.usePlainPrompt
            ? job.plainPrompt
            : (job.caption.toJSON() ?? job.caption.highLevelDescription)
        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .ideogram4 }
        let loraKey = loras.map { "\($0.path)@\(String(format: "%.2f", $0.strength))" }.joined(separator: ",")
        let outputs: [DriverOutput] = job.seeds.isEmpty
            ? [DriverOutput(seed: ctx.seed, path: ctx.outputFile)]
            : RunnerSupport.expandedPaths(from: ctx.outputFile, seeds: job.seeds)
            .map { DriverOutput(seed: $0.seed, path: $0.path) }
        let cfgEnd = settings.ideogram4CfgEnd.flatMap { $0 < 1.0 ? $0 : nil }

        return DriverGenerateRequest(
            id: job.id.uuidString,
            family: "ideogram4",
            fingerprint: "ideogram4|\(model)|q\(quantizeArg ?? 0)|\(loraKey)",
            model: model,
            quantize: quantizeArg,
            loraPaths: loras.map(\.path),
            loraScales: loras.map(\.strength),
            prompt: prompt,
            width: job.width,
            height: job.height,
            steps: job.preset.stepCount,
            guidance: 1.0, // unused — the preset defines the guidance schedule
            imagePath: nil,
            imageStrength: nil,
            preset: job.preset.rawValue,
            strictCaptionValidation: job.strictValidation,
            cfgEnd: cfgEnd,
            pidDecode: job.pidDecode,
            pidDegradeSigma: job.pidDegradeSigma,
            outputs: outputs,
            stepwiseDir: ctx.stepwiseDir.path,
            tePolicy: WarmTextEncoderPolicy.keep.rawValue, // driver forces keep for ideogram4
            cacheLimitGb: settings.mlxCacheLimitGB,
            modelVariantRaw: FluxModelVariant.ideogram4.rawValue,
            modelLabel: RunnerSupport.modelLabel(
                custom: job.customModelRepo, fallback: FluxModelVariant.ideogram4.displayName
            )
        )
    }

    static func buildArgs(job: Ideogram4Job, ctx: JobRunContext, settings: AppSettings) -> [String] {
        var args: [String] = []

        let (model, quantizeArg) = resolveModel(job: job, settings: settings)
        args += ["--model", model]

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

        // Nil whenever the resolved source already carries its own quantization
        // (custom/override repo, pre-quantized repo, or saved weights).
        if let quantizeArg {
            args += ["--quantize", "\(quantizeArg)"]
        }

        let enabledLoras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .ideogram4 }
        if !enabledLoras.isEmpty {
            args += ["--lora-paths"] + enabledLoras.map(\.path)
            args += ["--lora-scales"] + enabledLoras.map { String(format: "%.2f", $0.strength) }
        }

        if job.lowRam {
            args.append("--low-ram")
        }
        if settings.mlxCacheLimitGB > 0 {
            args += ["--mlx-cache-limit-gb", String(format: "%.1f", settings.mlxCacheLimitGB)]
        }
        if job.strictValidation {
            args.append("--strict-caption-validation")
        }
        if let cfgEnd = settings.ideogram4CfgEnd, cfgEnd < 1.0 {
            args += ["--cfg-end", String(format: "%.2f", cfgEnd)]
        }

        args += ["--stepwise-image-output-dir", ctx.stepwiseDir.path]

        // PiD decodes at 4x instead of the VAE. The flag only exists on an mflux that
        // has the decoder, and the toggle is hidden otherwise, so a stale install
        // cannot smuggle an unrecognised flag into the command line.
        if job.pidDecode {
            args += ["--pid-decode"]
            if job.pidDegradeSigma > 0 {
                args += ["--pid-degrade-sigma", String(format: "%.2f", job.pidDegradeSigma)]
            }
        }

        return args
    }
}
