import Foundation

/// Executes Krea 2 Turbo generation jobs by driving the `mflux-generate-krea2` CLI.
/// The shared ``JobRunner`` engine owns the process lifecycle; this spec supplies the
/// Krea-specific behavior. Weights come from `krea/Krea-2-Turbo`; for Q8/Q4 the
/// engine first runs a one-time `mflux-save` pass into the mflux cache dir, then
/// loads the saved dir on subsequent runs. BF16 loads the repo directly.
typealias Krea2JobRunner = JobRunner<Krea2RunnerSpec>

extension Krea2Job: GeneratedJob {}
extension Krea2JobStore: GenerationJobStore {}

enum Krea2RunnerSpec: JobRunnerSpec {
    typealias Job = Krea2Job
    typealias Store = Krea2JobStore

    static let family: ModelFamily = .krea2
    static let stepwiseSubdir = "stepwise-krea2"
    static let outputPrefix = "krea2"
    static let encodingLabel = "Generating"

    static func binaryName(job _: Krea2Job) -> String {
        "mflux-generate-krea2"
    }

    static func binaryPath(job _: Krea2Job, settings: AppSettings) -> String {
        settings.mfluxKrea2BinaryPath()
    }

    /// Q8/Q4: one-time mflux-save quantization pass into the cache dir.
    static func quantSaveDestination(job: Krea2Job, settings: AppSettings) -> URL? {
        guard job.quantize > 0 else { return nil }
        return FluxModelVariant.krea2.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
    }

    static func saveBinaryPath(settings: AppSettings) -> String {
        BinaryDetector.mfluxSave(in: settings.mfluxBinaryDir)
    }

    static func saveModelID(job _: Krea2Job) -> String {
        FluxModelVariant.krea2.mfluxModelID
    }

    /// img2img runs fewer denoise steps than requested (the image-strength schedule
    /// drops the leading steps), so the tqdm total can be < job.steps. Accept any
    /// genuine tqdm bar up to the requested count, otherwise the UI stays stuck on
    /// "Loading model…" for the whole img2img run.
    static func acceptsProgressTotal(_ total: Int, job: Krea2Job) -> Bool {
        total <= job.steps
    }

    static func timingModelKey(job _: Krea2Job) -> String {
        "krea2"
    }

    static func timingLowRam(job _: Krea2Job) -> Bool {
        false
    }

    static func writeMetadata(job: Krea2Job, seed: Int, startedAt: Date?, generatedAt: Date, path: String) {
        var meta = Krea2Metadata.from(job: job)
        meta.seed = seed
        meta.startedAt = startedAt
        meta.generatedAt = generatedAt
        MetadataSidecar.writeKrea2(meta, for: path)
    }

    /// Driver eligibility + request. Every Krea 2 job qualifies (no edit or
    /// low-RAM modes); model resolution mirrors buildArgs.
    static func driverRequest(job: Krea2Job, ctx: JobRunContext, settings: AppSettings) -> DriverGenerateRequest? {
        var model = FluxModelVariant.krea2.mfluxModelID
        var quantizeArg: Int?
        if job.quantize > 0 {
            let savedPath = FluxModelVariant.krea2.savedModelPath(
                quantize: job.quantize, in: settings.effectiveMfluxCacheDir
            )
            if FluxModelVariant.hasSavedWeights(at: savedPath) {
                model = savedPath.path
            } else {
                quantizeArg = job.quantize
            }
        }

        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .krea2 }
        let loraKey = loras.map { "\($0.path)@\(String(format: "%.2f", $0.strength))" }.joined(separator: ",")
        let outputs: [DriverOutput] = job.seeds.isEmpty
            ? [DriverOutput(seed: ctx.seed, path: ctx.outputFile)]
            : RunnerSupport.expandedPaths(from: ctx.outputFile, seeds: job.seeds)
            .map { DriverOutput(seed: $0.seed, path: $0.path) }
        let trimmedNegative = job.negativePrompt.trimmingCharacters(in: .whitespaces)

        return DriverGenerateRequest(
            id: job.id.uuidString,
            family: "krea2",
            fingerprint: "krea2|\(model)|q\(quantizeArg ?? 0)|\(loraKey)",
            model: model,
            quantize: quantizeArg,
            loraPaths: loras.map(\.path),
            loraScales: loras.map(\.strength),
            prompt: job.prompt,
            negativePrompt: job.guidance != 1.0 && !trimmedNegative.isEmpty ? job.negativePrompt : nil,
            width: job.width,
            height: job.height,
            steps: job.steps,
            guidance: job.guidance,
            imagePath: job.imagePath.isEmpty ? nil : job.imagePath,
            imageStrength: job.imagePath.isEmpty ? nil : job.imageStrength,
            preset: nil,
            strictCaptionValidation: nil,
            cfgEnd: nil,
            outputs: outputs,
            stepwiseDir: ctx.stepwiseDir.path,
            tePolicy: WarmTextEncoderPolicy.keep.rawValue, // resolved per-run by the controller
            cacheLimitGb: settings.mlxCacheLimitGB,
            modelVariantRaw: FluxModelVariant.krea2.rawValue,
            modelLabel: FluxModelVariant.krea2.displayName
        )
    }

    static func buildArgs(job: Krea2Job, ctx: JobRunContext, settings: AppSettings) -> [String] {
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
}
