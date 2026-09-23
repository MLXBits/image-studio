import Foundation

/// Executes Qwen-Image 2.1 generation jobs by driving the `mflux-generate-qwen-2.1`
/// CLI (mflux 0.20.0+). The shared ``JobRunner`` engine owns the process lifecycle;
/// this spec supplies the Qwen-Image-specific behavior. Weights come from
/// `Qwen/Qwen-Image-2.1` (diffusers layout, converted on load). Q8/Q4 quantize the
/// DiT in memory at load (the Qwen3-VL text encoder always stays BF16), so there
/// is no `mflux-save` pass and no pre-quantized repo. Runs as a subprocess only;
/// the warm driver has no Qwen-Image pipeline.
typealias QwenImageJobRunner = JobRunner<QwenImageRunnerSpec>

extension QwenImageJob: GeneratedJob {}
extension QwenImageJobStore: GenerationJobStore {}

enum QwenImageRunnerSpec: JobRunnerSpec {
    typealias Job = QwenImageJob
    typealias Store = QwenImageJobStore

    static let family: ModelFamily = .qwenImage
    static let stepwiseSubdir = "stepwise-qwenimage"
    static let outputPrefix = "qwenimage"
    static let encodingLabel = "Generating"

    /// Qwen-Image 2.1 is trained guidance-free. mflux runs true classifier-free
    /// guidance only when guidance is above 1 *and* a negative prompt is present,
    /// so below that threshold the negative prompt is dropped rather than sent to
    /// be silently ignored.
    static func negativePromptArg(for job: QwenImageJob) -> String? {
        guard job.usesTrueCFG else { return nil }
        let trimmed = job.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : job.negativePrompt
    }

    static func binaryName(job _: QwenImageJob) -> String {
        "mflux-generate-qwen-2.1"
    }

    static func binaryPath(job _: QwenImageJob, settings: AppSettings) -> String {
        settings.mfluxQwenImageBinaryPath()
    }

    /// Never an `mflux-save` pass: quantization happens in memory at load.
    static func quantSaveDestination(job _: QwenImageJob, settings _: AppSettings) -> URL? {
        nil
    }

    static func saveBinaryPath(settings: AppSettings) -> String {
        BinaryDetector.mfluxSave(in: settings.mfluxBinaryDir)
    }

    static func saveModelID(job: QwenImageJob) -> String {
        job.modelVariant.mfluxModelID
    }

    /// img2img runs fewer denoise steps than requested (the image-strength schedule
    /// drops the leading steps), so the tqdm total can be < job.steps.
    static func acceptsProgressTotal(_ total: Int, job: QwenImageJob) -> Bool {
        total <= job.steps
    }

    static func timingModelKey(job: QwenImageJob) -> String {
        TimingStore.modelKey(job.modelVariant.rawValue, customRepo: job.customModelRepo)
    }

    static func timingLowRam(job _: QwenImageJob) -> Bool {
        false
    }

    static func writeMetadata(job: QwenImageJob, seed: Int, startedAt: Date?, generatedAt: Date, path: String) {
        var meta = QwenImageMetadata.from(job: job)
        meta.seed = seed
        meta.startedAt = startedAt
        meta.generatedAt = generatedAt
        MetadataSidecar.writeQwenImage(meta, for: path)
    }

    /// A repo ID or path that replaces the official checkpoint: the picker's
    /// `Custom…` entry first, then the Settings → Models override. Both name a
    /// specific set of weights, so neither takes a `--quantize` pass.
    private static func modelSourceOverride(job: QwenImageJob, settings: AppSettings) -> String? {
        let custom = job.customModelRepo.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            return custom
        }
        let override = (settings.defaults(for: job.modelVariant).modelRepoOverride ?? "")
            .trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? nil : override
    }

    static func buildArgs(job: QwenImageJob, ctx: JobRunContext, settings: AppSettings) -> [String] {
        arguments(
            job: job, ctx: ctx,
            modelSource: modelSourceOverride(job: job, settings: settings),
            mlxCacheLimitGB: settings.mlxCacheLimitGB
        )
    }

    /// The CLI arguments for `job`, given the settings-derived inputs already
    /// resolved: `modelSource` is the custom/override checkpoint (nil = official).
    /// Split from ``buildArgs(job:ctx:settings:)`` so it is testable without an
    /// `AppSettings`, which reads and writes the user's settings file.
    static func arguments(
        job: QwenImageJob, ctx: JobRunContext, modelSource: String?, mlxCacheLimitGB: Double
    ) -> [String] {
        var args: [String] = []

        if let source = modelSource {
            // `--base-model` pins the geometry mflux loads a third-party checkpoint as.
            args += ["--model", source, "--base-model", job.modelVariant.mfluxModelID]
        } else {
            args += ["--model", job.modelVariant.mfluxModelID]
            if job.quantize > 0 {
                args += ["--quantize", "\(job.quantize)"]
            }
        }

        args += ["--prompt", job.prompt]
        if let negative = negativePromptArg(for: job) {
            args += ["--negative-prompt", negative]
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

        // img2img: an init image seeds the latents; empty path = pure text-to-image.
        // The CLI only exists on mflux 0.20.0+, which has the atomic `--image PATH STRENGTH`.
        if !job.imagePath.isEmpty {
            args += ["--image", job.imagePath, String(format: "%.2f", job.imageStrength)]
        }

        if mlxCacheLimitGB > 0 {
            args += ["--mlx-cache-limit-gb", String(format: "%.1f", mlxCacheLimitGB)]
        }

        args += ["--stepwise-image-output-dir", ctx.stepwiseDir.path]

        return args
    }
}
