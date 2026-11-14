import Foundation

/// Executes Qwen-Image 2.1 Turbo jobs through `mflux-generate-qwen-2.1-edit`,
/// which does text-to-image with no references and multi-reference editing
/// with them. Weights load straight from the mflux-community repo for the
/// chosen precision (BF16, Q8, Q4): there is no `mflux-save` pass and no
/// `--quantize`. With Keep Model Warm on, jobs run on the warm driver except
/// low-RAM ones, which stay on the one-shot CLI.
typealias Qwen21JobRunner = JobRunner<Qwen21RunnerSpec>

extension Qwen21Job: @MainActor QueueListedJob {}
extension Qwen21JobStore: @MainActor GenerationJobStore {}

enum Qwen21RunnerSpec: @MainActor JobRunnerSpec {
    typealias Job = Qwen21Job
    typealias Store = Qwen21JobStore

    static let family: ModelFamily = .qwen21
    static let stepwiseSubdir = "stepwise-qwen21"
    static let outputPrefix = "qwen21"
    static let encodingLabel = "Generating"

    static func tool(job _: Qwen21Job) -> PythonTool {
        .qwen21Edit
    }

    static func accessPaths(job: Qwen21Job) -> [String] {
        let images = job.isEditMode ? job.editImagePaths : []
        return (enabledLoras(job).map(\.path) + [job.customModelRepo] + images).filter(FileAccessPath.isLocal)
    }

    static func quantSaveDestination(job _: Qwen21Job, settings _: AppSettings) -> URL? {
        nil
    }

    static func saveModelID(job _: Qwen21Job) -> String {
        FluxModelVariant.qwen21Turbo.mfluxModelID
    }

    static func acceptsProgressTotal(_ total: Int, job: Qwen21Job) -> Bool {
        total == job.steps
    }

    static func timingModelKey(job: Qwen21Job) -> String {
        TimingStore.modelKey("qwen21", customRepo: job.customModelRepo)
    }

    static func timingLowRam(job: Qwen21Job) -> Bool {
        job.lowRam
    }

    static func writeMetadata(job: Qwen21Job, seed: Int, startedAt: Date?, generatedAt: Date, path: String) {
        var meta = Qwen21Metadata.from(job: job)
        meta.seed = seed
        meta.startedAt = startedAt
        meta.generatedAt = generatedAt
        MetadataSidecar.writeQwen21(meta, for: path)
    }

    /// The `--model` value: the picker's custom checkpoint, else the published
    /// repo for the job's precision.
    static func model(job: Qwen21Job) -> String {
        let custom = job.customModelRepo.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            return custom
        }
        let variant = FluxModelVariant.qwen21Turbo
        return variant.preQuantizedRepoID(quantize: job.quantize) ?? variant.mfluxModelID
    }

    /// Low-RAM jobs stream blocks from disk, which a resident model defeats, so
    /// they stay on the one-shot CLI. The driver tiles the VAE decode as the CLI
    /// does, caches each prompt + references encoding, and evicts the text encoder
    /// per the warm-TE policy, reloading it only when an encoding misses.
    static func driverRequest(job: Qwen21Job, ctx: JobRunContext, settings: AppSettings) -> DriverGenerateRequest? {
        guard !job.lowRam else { return nil }
        let model = model(job: job)
        let loras = enabledLoras(job)
        let references = job.isEditMode ? job.editImagePaths : []
        let variant = FluxModelVariant.qwen21Turbo
        return DriverGenerateRequest(
            id: job.id.uuidString,
            family: "qwen21",
            fingerprint: "qwen21|\(model)|\(RunnerSupport.driverLoraKey(loras))",
            model: model,
            baseModel: variant.mfluxModelID,
            loraPaths: loras.map(\.path),
            loraScales: loras.map(\.strength),
            prompt: job.prompt,
            width: job.followsReferenceSize ? nil : job.width,
            height: job.followsReferenceSize ? nil : job.height,
            steps: job.steps,
            guidance: 1.0,
            imagePaths: references,
            outputs: RunnerSupport.driverOutputs(ctx: ctx, seeds: job.seeds),
            stepwiseDir: "", // no previews, as in buildArgs
            tePolicy: WarmTextEncoderPolicy.keep.rawValue,
            cacheLimitGb: settings.mlxCacheLimitGB,
            modelVariantRaw: variant.rawValue,
            modelLabel: RunnerSupport.modelLabel(custom: job.customModelRepo, fallback: variant.displayName)
        )
    }

    static func buildArgs(job: Qwen21Job, ctx: JobRunContext, settings: AppSettings) -> [String] {
        // --base-model on every run: mflux 0.24.0 has no alias for the `qwen-image-2-1-turbo`
        // repo names (added after it, in mflux #937) and silently runs them on the base
        // model's 40-step config. The variant's mflux ID is the Turbo registry key.
        var args = ["--model", model(job: job), "--base-model", FluxModelVariant.qwen21Turbo.mfluxModelID]
        args += ["--prompt", job.prompt, "--steps", "\(job.steps)", "--output", ctx.outputFile]
        args += ["--seed"] + (job.seeds.isEmpty ? [ctx.seed] : job.seeds).map { "\($0)" }

        if job.isEditMode, !job.editImagePaths.isEmpty {
            args += ["--image-paths"] + job.editImagePaths
        }
        // With no size, mflux sizes an edit from the last reference.
        if !job.followsReferenceSize {
            args += ["--width", "\(job.width)", "--height", "\(job.height)"]
        }

        let loras = enabledLoras(job)
        if !loras.isEmpty {
            args += ["--lora-paths"] + loras.map(\.path)
            args += ["--lora-scales"] + loras.map { String(format: "%.2f", $0.strength) }
        }
        // mflux runs this VAE in fp32: untiled, the decode alone needs ~14 GB at 1344x768.
        args.append(job.lowRam ? "--low-ram" : "--vae-tiling")
        if settings.mlxCacheLimitGB > 0 {
            args += ["--mlx-cache-limit-gb", String(format: "%.1f", settings.mlxCacheLimitGB)]
        }
        // No stepwise previews: they are noise until step 6 of 8, and mflux decodes each
        // one untiled in fp32 (~11 GB over the tiled decode's peak at 1344x768).
        return args
    }

    private static func enabledLoras(_ job: Qwen21Job) -> [LoraEntry] {
        job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .qwen21 }
    }
}
