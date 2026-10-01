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

    /// Remote upscale on ComfyUI's core SeedVR2 nodes. Every Upscale-sheet control carries over except quantize: the server
    /// file's own precision (int8 by preference) stands in for it. Model files are picked from the server's loader options,
    /// so there is nothing to configure beyond the backend segment; a missing model fails the job instead of running it
    /// locally, since remote was asked for.
    static func comfyGraph(job: SeedVR2Job, settings _: AppSettings, client: ComfyUIClient) async throws -> ComfyGraph? {
        guard let size = seedVR2PixelSize(ofImageAt: job.sourcePath) else {
            throw ComfyUIError.decodeFailed("could not read the source image at \(job.sourcePath)")
        }
        let unets = try await client.loaderOptions(nodeClass: "UNETLoader", input: "unet_name")
        let vaes = try await client.loaderOptions(nodeClass: "VAELoader", input: "vae_name")
        guard let files = ComfyUIClient.pickSeedVR2Files(unets: unets, vaes: vaes, is7B: job.is7B) else {
            throw ComfyUIError.executionFailed(
                "no \(job.modelLabel) model on the server — expected a seedvr2_\(job.is7B ? "7b" : "3b") file in "
                    + "models/diffusion_models and a seedvr2 VAE in models/vae"
            )
        }
        let geometry = ComfyUIClient.seedVR2Geometry(
            sourceWidth: Int(size.width), sourceHeight: Int(size.height), scale: job.scale, softness: job.softness
        )

        job.statusLine = "Uploading source to ComfyUI…"
        let imageName = try await client.uploadImage(localPath: job.sourcePath)
        job.log += "ComfyUI: \(files.unet) · \(geometry.width)×\(geometry.height)"
            + (geometry.softWidth.map { " · softened via \($0)×\(geometry.softHeight ?? 0)" } ?? "") + "\n"

        let input = ComfyUIClient.SeedVR2WorkflowInput(
            imageName: imageName, geometry: geometry, seed: 0,
            unetName: files.unet, vaeName: files.vae, saveSubfolder: family.id
        )
        return ComfyGraph(totalNodes: ComfyUIClient.seedVR2NodeCount(geometry), totalSteps: 1) { seed in
            var seeded = input
            seeded.seed = seed
            return client.buildSeedVR2Workflow(seeded)
        }
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
