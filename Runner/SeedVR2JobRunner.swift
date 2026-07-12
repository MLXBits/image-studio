import Foundation

/// Executes SeedVR2 upscale jobs by driving the `mflux-upscale-seedvr2` CLI.
/// The shared ``JobRunner`` engine owns the process lifecycle; this spec supplies the
/// SeedVR2-specific behavior. SeedVR2 is prompt-free super-resolution: weights load
/// directly by builtin name (`seedvr2-3b`/`seedvr2-7b`), quantized in-memory — there
/// is no `mflux-save` pass and no warm-driver support (upscales are occasional, not
/// back-to-back), so it always uses the one-shot CLI path.
typealias SeedVR2JobRunner = JobRunner<SeedVR2RunnerSpec>

extension SeedVR2Job: GeneratedJob {}
extension SeedVR2JobStore: GenerationJobStore {}

enum SeedVR2RunnerSpec: JobRunnerSpec {
    typealias Job = SeedVR2Job
    typealias Store = SeedVR2JobStore

    static let family: ModelFamily = .seedvr2
    static let stepwiseSubdir = "stepwise-seedvr2"
    static let outputPrefix = "seedvr2"
    static let encodingLabel = "Upscaling"

    static func binaryName(job _: SeedVR2Job) -> String {
        "mflux-upscale-seedvr2"
    }

    static func binaryPath(job _: SeedVR2Job, settings: AppSettings) -> String {
        settings.mfluxSeedVR2BinaryPath()
    }

    /// SeedVR2 loads weights directly by builtin name; no one-time save pass.
    static func quantSaveDestination(job _: SeedVR2Job, settings _: AppSettings) -> URL? {
        nil
    }

    static func saveBinaryPath(settings _: AppSettings) -> String {
        "" // unused — quantSaveDestination is always nil
    }

    static func saveModelID(job _: SeedVR2Job) -> String {
        "" // unused — quantSaveDestination is always nil
    }

    /// Accept SeedVR2's own tqdm bar whatever its step count (often just 1 step).
    static func acceptsProgressTotal(_: Int, job _: SeedVR2Job) -> Bool {
        true
    }

    static func timingModelKey(job: SeedVR2Job) -> String {
        job.is7B ? "seedvr2-7b" : "seedvr2-3b"
    }

    static func timingLowRam(job _: SeedVR2Job) -> Bool {
        false
    }

    static func writeMetadata(job: SeedVR2Job, seed: Int, startedAt: Date?, generatedAt: Date, path: String) {
        var meta = SeedVR2Metadata.from(job: job)
        meta.seed = seed
        meta.startedAt = startedAt
        meta.generatedAt = generatedAt
        MetadataSidecar.writeSeedVR2(meta, for: path)
    }

    static func buildArgs(job: SeedVR2Job, ctx: JobRunContext, settings: AppSettings) -> [String] {
        var args: [String] = []

        args += ["--model", job.is7B ? "seedvr2-7b" : "seedvr2-3b"]
        args += ["--image-path", job.sourcePath]
        args += ["--resolution", "\(job.scale)x"]
        args += ["--softness", String(format: "%.2f", job.softness)]
        args += ["--seed", "\(ctx.seed)"]
        args += ["--output", ctx.outputFile]

        if job.quantize > 0 {
            args += ["--quantize", "\(job.quantize)"]
        }

        if settings.mlxCacheLimitGB > 0 {
            args += ["--mlx-cache-limit-gb", String(format: "%.1f", settings.mlxCacheLimitGB)]
        }

        // No --stepwise-image-output-dir: SeedVR2LatentCreator has no unpack_latents,
        // so mflux's StepwiseHandler crashes on the before-loop save. SeedVR2 is a
        // ~single-step upscale, so per-step previews add nothing anyway.
        return args
    }
}
