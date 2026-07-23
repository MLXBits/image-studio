import Foundation

/// Executes Z-Image generation jobs by driving the `mflux-generate-z-image` /
/// `mflux-generate-z-image-turbo` CLIs. The shared ``JobRunner`` engine owns the
/// process lifecycle; this spec supplies the Z-Image-specific behavior. Weights
/// come from `Tongyi-MAI/Z-Image[-Turbo]`; Turbo Q4 loads the pre-quantized
/// `filipstrand/Z-Image-Turbo-mflux-4bit` repo directly, while every other
/// quantized variant runs a one-time `mflux-save` pass into the mflux cache dir.
/// BF16 loads the repo directly.
typealias ZImageJobRunner = JobRunner<ZImageRunnerSpec>

extension ZImageJob: GeneratedJob {}
extension ZImageJobStore: GenerationJobStore {}

enum ZImageRunnerSpec: JobRunnerSpec {
    typealias Job = ZImageJob
    typealias Store = ZImageJobStore

    static let family: ModelFamily = .zimage
    static let stepwiseSubdir = "stepwise-zimage"
    static let outputPrefix = "zimage"
    static let encodingLabel = "Generating"

    /// Base Z-Image supports classifier-free guidance and a negative prompt; the
    /// distilled Turbo variant runs guidance-free (the model forces guidance 0), so
    /// its negative prompt has no effect and is dropped.
    private static func negativePromptArg(for job: ZImageJob) -> String? {
        guard !job.isTurbo else { return nil }
        let trimmed = job.negativePrompt.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : job.negativePrompt
    }

    static func binaryName(job: ZImageJob) -> String {
        job.isTurbo ? "mflux-generate-z-image-turbo" : "mflux-generate-z-image"
    }

    static func binaryPath(job: ZImageJob, settings: AppSettings) -> String {
        settings.mfluxZImageBinaryPath(turbo: job.isTurbo)
    }

    /// Q8/Q4: one-time mflux-save quantization pass into the cache dir — unless a
    /// pre-quantized repo exists (Turbo Q4), which loads directly.
    static func quantSaveDestination(job: ZImageJob, settings: AppSettings) -> URL? {
        guard job.quantize > 0 else { return nil }
        if job.modelVariant.preQuantizedRepoID(quantize: job.quantize) != nil { return nil }
        return job.modelVariant.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
    }

    static func saveBinaryPath(settings: AppSettings) -> String {
        BinaryDetector.mfluxSave(in: settings.mfluxBinaryDir)
    }

    static func saveModelID(job: ZImageJob) -> String {
        job.modelVariant.mfluxModelID
    }

    /// img2img runs fewer denoise steps than requested (the image-strength schedule
    /// drops the leading steps), so the tqdm total can be < job.steps.
    static func acceptsProgressTotal(_ total: Int, job: ZImageJob) -> Bool {
        total <= job.steps
    }

    static func timingModelKey(job: ZImageJob) -> String {
        job.modelVariant.rawValue // "z-image-turbo" or "z-image"
    }

    static func timingLowRam(job _: ZImageJob) -> Bool {
        false
    }

    static func writeMetadata(job: ZImageJob, seed: Int, startedAt: Date?, generatedAt: Date, path: String) {
        var meta = ZImageMetadata.from(job: job)
        meta.seed = seed
        meta.startedAt = startedAt
        meta.generatedAt = generatedAt
        MetadataSidecar.writeZImage(meta, for: path)
    }

    /// Resolves the `--model` argument (repo ID, pre-quantized repo, or local
    /// mflux-saved dir), mirroring `buildArgs`, plus the in-memory quantize
    /// fallback. Returns `(model, quantizeArg)`.
    private static func resolveModel(job: ZImageJob, settings: AppSettings) -> (model: String, quantize: Int?) {
        guard job.quantize > 0 else { return (job.modelVariant.mfluxModelID, nil) }
        if let preQuant = job.modelVariant.preQuantizedRepoID(quantize: job.quantize) {
            return (preQuant, nil)
        }
        let savedPath = job.modelVariant.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
        if FluxModelVariant.hasSavedWeights(at: savedPath) {
            return (savedPath.path, nil)
        }
        return (job.modelVariant.mfluxModelID, job.quantize)
    }

    /// Driver eligibility + request. Every Z-Image job qualifies; model resolution
    /// mirrors buildArgs. `modelVariantRaw` tells the driver which ModelConfig
    /// (Turbo vs base) to construct.
    static func driverRequest(job: ZImageJob, ctx: JobRunContext, settings: AppSettings) -> DriverGenerateRequest? {
        let (model, quantizeArg) = resolveModel(job: job, settings: settings)
        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .zimage }
        let loraKey = loras.map { "\($0.path)@\(String(format: "%.2f", $0.strength))" }.joined(separator: ",")
        let outputs: [DriverOutput] = job.seeds.isEmpty
            ? [DriverOutput(seed: ctx.seed, path: ctx.outputFile)]
            : RunnerSupport.expandedPaths(from: ctx.outputFile, seeds: job.seeds)
            .map { DriverOutput(seed: $0.seed, path: $0.path) }

        return DriverGenerateRequest(
            id: job.id.uuidString,
            family: "z_image",
            fingerprint: "z_image|\(job.modelVariant.rawValue)|\(model)|q\(quantizeArg ?? 0)|\(loraKey)",
            model: model,
            quantize: quantizeArg,
            loraPaths: loras.map(\.path),
            loraScales: loras.map(\.strength),
            prompt: job.prompt,
            negativePrompt: negativePromptArg(for: job),
            width: job.width,
            height: job.height,
            steps: job.steps,
            guidance: job.isTurbo ? 0.0 : job.guidance,
            imagePath: job.imagePath.isEmpty ? nil : job.imagePath,
            imageStrength: job.imagePath.isEmpty ? nil : job.imageStrength,
            preset: nil,
            strictCaptionValidation: nil,
            cfgEnd: nil,
            outputs: outputs,
            stepwiseDir: ctx.stepwiseDir.path,
            tePolicy: WarmTextEncoderPolicy.keep.rawValue, // resolved per-run by the controller
            cacheLimitGb: settings.mlxCacheLimitGB,
            modelVariantRaw: job.modelVariant.rawValue,
            modelLabel: job.modelVariant.displayName
        )
    }

    static func buildArgs(job: ZImageJob, ctx: JobRunContext, settings: AppSettings) -> [String] {
        var args: [String] = []

        let (model, quantizeArg) = resolveModel(job: job, settings: settings)
        args += ["--model", model]

        args += ["--prompt", job.prompt]
        // Base Z-Image only: negative prompt requires classifier-free guidance.
        if let negative = negativePromptArg(for: job) {
            args += ["--negative-prompt", negative]
        }
        args += ["--width", "\(job.width)", "--height", "\(job.height)"]
        args += ["--steps", "\(job.steps)"]
        // Guidance only for base; Turbo is guidance-free (model forces 0).
        if !job.isTurbo {
            args += ["--guidance", String(format: "%.2f", job.guidance)]
        }
        args += ["--output", ctx.outputFile]

        if job.seeds.isEmpty {
            args += ["--seed", "\(ctx.seed)"]
        } else {
            args += ["--seed"] + job.seeds.map { "\($0)" }
        }

        // No saved/pre-quantized weights: quantize in memory.
        if let quantizeArg {
            args += ["--quantize", "\(quantizeArg)"]
        }

        // img2img: an init image seeds the latents; empty path = pure text-to-image.
        if !job.imagePath.isEmpty {
            args += [
                "--image-path", job.imagePath,
                "--image-strength", String(format: "%.2f", job.imageStrength),
            ]
        }

        let enabledLoras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .zimage }
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
}
