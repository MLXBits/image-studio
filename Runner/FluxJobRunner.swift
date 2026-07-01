import Foundation

/// Executes FLUX generation jobs by driving the `mflux-generate-flux2` /
/// `mflux-generate-flux2-edit` CLI. The shared ``JobRunner`` engine owns the
/// process lifecycle; this spec supplies the FLUX-specific behavior.
typealias FluxJobRunner = JobRunner<FluxRunnerSpec>

extension FluxJob: GeneratedJob {}
extension JobStore: GenerationJobStore {}

enum FluxRunnerSpec: JobRunnerSpec {
    typealias Job = FluxJob
    typealias Store = JobStore

    static let family: ModelFamily = .flux
    static let stepwiseSubdir = "stepwise"
    static let outputPrefix = "image"
    static let encodingLabel = "Encoding prompt"

    static func binaryName(job: FluxJob) -> String {
        job.isEditMode ? "mflux-generate-flux2-edit" : "mflux-generate-flux2"
    }

    static func binaryPath(job: FluxJob, settings: AppSettings) -> String {
        job.isEditMode ? settings.mfluxEditBinaryPath() : settings.mfluxBinaryPath()
    }

    /// For quantized non-custom models without a published pre-quantized repo, a local
    /// saved copy lets every subsequent load skip in-memory quantization.
    static func quantSaveDestination(job: FluxJob, settings: AppSettings) -> URL? {
        guard job.quantize > 0, job.model != .custom,
              job.model.preQuantizedRepoID(quantize: job.quantize) == nil else { return nil }
        return job.model.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
    }

    static func saveBinaryPath(settings: AppSettings) -> String {
        BinaryDetector.mfluxSave(in: settings.mfluxBinaryDir)
    }

    static func saveModelID(job: FluxJob) -> String {
        job.model.mfluxModelID
    }

    /// img2img runs fewer denoise steps than requested (the image-strength schedule
    /// drops the leading steps), so the tqdm total can be < job.steps. Accept any
    /// genuine tqdm bar up to the requested count rather than requiring exact equality.
    static func acceptsProgressTotal(_ total: Int, job: FluxJob) -> Bool {
        total <= job.steps
    }

    static func timingModelKey(job: FluxJob) -> String {
        TimingStore.fluxModelKey(job.model, customRepo: job.customModelRepo)
    }

    static func timingLowRam(job: FluxJob) -> Bool {
        job.lowRam
    }

    static func writeMetadata(job: FluxJob, seed: Int, startedAt: Date?, generatedAt: Date, path: String) {
        var meta = GenerationMetadata.from(job: job)
        meta.seed = seed
        meta.startedAt = startedAt
        meta.generatedAt = generatedAt
        MetadataSidecar.write(meta, for: path)
    }

    static func buildArgs(job: FluxJob, ctx: JobRunContext, settings: AppSettings) -> [String] {
        var args: [String] = []

        if job.model == .custom {
            args += ["--model", job.customModelRepo, "--base-model", job.customBaseModel.mfluxModelID]
        } else if let override = settings.defaults(for: job.model).modelRepoOverride, !override.isEmpty {
            // User-supplied override (HF repo ID or local path): use as-is.
            // No --quantize flag — the repo carries its own quantization metadata.
            args += ["--model", override]
        } else if job.quantize > 0 {
            if let preQuantizedRepo = job.model.preQuantizedRepoID(quantize: job.quantize) {
                // Known mlx-community pre-quantized repo: pass directly, mflux detects stored_q.
                args += ["--model", preQuantizedRepo]
            } else {
                let savedPath = job.model.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
                if FluxModelVariant.hasSavedWeights(at: savedPath) {
                    // Local mflux-saved weights: pass path directly, mflux detects stored_q.
                    args += ["--model", savedPath.path]
                } else {
                    // No saved weights yet (mflux-save may have failed): fall back to in-memory quantization.
                    args += ["--model", job.model.mfluxModelID]
                }
            }
        } else {
            args += ["--model", job.model.mfluxModelID]
        }

        args += ["--prompt", job.prompt]

        let supportsNeg = job.model.supportsNegativePrompt
        if supportsNeg, !job.negativePrompt.isEmpty {
            args += ["--negative-prompt", job.negativePrompt]
        }

        args += [
            "--width", "\(job.width)",
            "--height", "\(job.height)",
            "--steps", "\(job.steps)",
            "--guidance", String(format: "%.2f", job.guidance),
            "--output", ctx.outputFile,
        ]

        if job.seeds.isEmpty {
            args += ["--seed", "\(ctx.seed)"]
        } else {
            args += ["--seed"] + job.seeds.map { "\($0)" }
        }

        // Only pass --quantize when falling back to in-memory quantization (BF16 base model).
        // Overrides, pre-quantized repos, and locally saved weights carry stored_q in metadata.
        if job.quantize > 0 {
            let hasOverride = !(settings.defaults(for: job.model).modelRepoOverride ?? "").isEmpty
            let hasPreQuantizedRepo = job.model != .custom && job.model.preQuantizedRepoID(quantize: job.quantize) != nil
            let savedPath = job.model.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
            let hasSaved = job.model != .custom && FluxModelVariant.hasSavedWeights(at: savedPath)
            if !hasOverride && !hasPreQuantizedRepo && !hasSaved {
                args += ["--quantize", "\(job.quantize)"]
            }
        }
        if job.lowRam { args.append("--low-ram") }
        if settings.mlxCacheLimitGB > 0 {
            args += ["--mlx-cache-limit-gb", String(format: "%.1f", settings.mlxCacheLimitGB)]
        }

        if job.isEditMode {
            if !job.editImagePaths.isEmpty {
                args += ["--image-paths"] + job.editImagePaths
            }
        } else if !job.imagePath.isEmpty {
            args += [
                "--image-path", job.imagePath,
                "--image-strength", String(format: "%.2f", job.imageStrength),
            ]
        }

        let enabledLoras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .flux }
        if !enabledLoras.isEmpty {
            args += ["--lora-paths"] + enabledLoras.map(\.path)
            args += ["--lora-scales"] + enabledLoras.map { String(format: "%.2f", $0.strength) }
        }

        args += ["--stepwise-image-output-dir", ctx.stepwiseDir.path]

        return args
    }
}
