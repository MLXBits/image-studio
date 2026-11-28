import Foundation

/// Executes Z-Image generation jobs by driving the `mflux-generate-z-image` /
/// `mflux-generate-z-image-turbo` CLIs. The shared ``JobRunner`` engine owns the
/// process lifecycle; this spec supplies the Z-Image-specific behavior. Every
/// precision loads its `mflux-community/z-image-{turbo,base}-mflux-*` repo directly
/// (see ``FluxModelVariant/publishedRepoID(quantize:)``), unless a legacy mflux-save
/// copy is already on disk.
typealias ZImageJobRunner = JobRunner<ZImageRunnerSpec>

extension ZImageJob: @MainActor QueueListedJob {
    var queueTitle: String {
        prompt
    }
}

enum ZImageRunnerSpec: @MainActor JobRunnerSpec {
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

    static func preview(_ job: ZImageJob) -> PreviewState {
        .activeZImageJob(job)
    }

    static func tool(job: ZImageJob) -> PythonTool {
        job.isTurbo ? .zImageTurbo : .zImage
    }

    /// Exactly what the run reads: enabled LoRAs of this family, the model folder, and its image.
    static func accessPaths(job: ZImageJob) -> [String] {
        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .zimage }.map(\.path)
        return (loras + [job.customModelRepo, job.imagePath]).filter(FileAccessPath.isLocal)
    }

    /// img2img runs fewer denoise steps than requested (the image-strength schedule
    /// drops the leading steps), so the tqdm total can be < job.steps.
    static func acceptsProgressTotal(_ total: Int, job: ZImageJob) -> Bool {
        total <= job.steps
    }

    static func timingModelKey(job: ZImageJob) -> String {
        // "z-image-turbo" or "z-image", or that plus the custom repo.
        TimingStore.modelKey(job.modelVariant.rawValue, customRepo: job.customModelRepo)
    }

    static func timingLowRam(job _: ZImageJob) -> Bool {
        false
    }

    static func writeMetadata(job: ZImageJob, seed: Int, startedAt: Date?, generatedAt: Date, path: String) {
        var meta = ZImageMetadata.from(job: job)
        meta.seed = seed
        meta.startedAt = startedAt
        meta.generatedAt = generatedAt
        MetadataSidecar.write(meta, for: path)
    }

    /// A repo ID or path that replaces the stock Z-Image model source: the picker's
    /// `Custom…` entry first, then the Settings → Models override for this variant.
    /// Both name a specific set of weights, so neither takes a `--quantize` pass.
    private static func modelSourceOverride(job: ZImageJob, settings: AppSettings) -> String? {
        let custom = job.customModelRepo.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            return custom
        }
        let override = (settings.defaults(for: job.modelVariant).modelRepoOverride ?? "")
            .trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? nil : override
    }

    /// Resolves the `--model` argument and the in-memory `--quantize` that goes with it,
    /// mirroring `buildArgs`. Precedence: custom repo → Settings override → a legacy
    /// mflux-saved copy → the published repo for the precision → the registry name,
    /// which no stock level reaches. Returns `(model, quantizeArg)`.
    private static func resolveModel(job: ZImageJob, settings: AppSettings) -> (model: String, quantize: Int?) {
        if let source = modelSourceOverride(job: job, settings: settings) {
            return (source, nil)
        }
        let variant = job.modelVariant
        if let saved = variant.legacySavedWeights(quantize: job.quantize, in: settings.effectiveMfluxCacheDir) {
            return (saved.path, nil)
        }
        if let repo = variant.publishedRepoID(quantize: job.quantize) {
            return (repo, nil)
        }
        return (variant.mfluxModelID, job.quantize > 0 ? job.quantize : nil)
    }

    /// Driver eligibility + request. Every Z-Image job qualifies; model resolution
    /// mirrors buildArgs. `modelVariantRaw` tells the driver which ModelConfig
    /// (Turbo vs base) to construct.
    static func driverRequest(job: ZImageJob, ctx: JobRunContext, settings: AppSettings) -> DriverGenerateRequest? {
        let (model, quantizeArg) = resolveModel(job: job, settings: settings)
        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .zimage }

        return DriverGenerateRequest(
            id: job.id.uuidString,
            family: "z_image",
            fingerprint: "z_image|\(job.modelVariant.rawValue)|\(model)|q\(quantizeArg ?? 0)|\(RunnerSupport.driverLoraKey(loras))",
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
            pidDecode: job.pidDecode,
            pidDegradeSigma: job.pidDegradeSigma,
            outputs: RunnerSupport.driverOutputs(ctx: ctx, seeds: job.seeds),
            stepwiseDir: ctx.stepwiseDir.path,
            tePolicy: WarmTextEncoderPolicy.keep.rawValue, // resolved per-run by the controller
            cacheLimitGb: settings.mlxCacheLimitGB,
            modelVariantRaw: job.modelVariant.rawValue,
            selectionKey: ModelSelection(variant: job.modelVariant, quantize: job.quantize, customRepo: job.customModelRepo).key
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
