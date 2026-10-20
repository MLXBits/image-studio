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

    static func tool(job: FluxJob) -> PythonTool {
        // A custom checkpoint runs through whatever family it loads as, so its target's
        // variant decides — a flux3 fine-tune needs the flux3 CLI.
        let m = job.model == .custom ? job.customBaseModel : job.model
        if m.isFlux3 {
            return job.isEditMode ? .flux3Edit : .flux3
        }
        return job.isEditMode ? .flux2Edit : .flux2
    }

    /// Exactly what the run reads: enabled Flux LoRAs, the custom folder only
    /// for the custom model, and the images of the job's mode.
    static func accessPaths(job: FluxJob) -> [String] {
        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .flux }.map(\.path)
        let model = job.model == .custom ? [job.customModelRepo] : []
        let images = job.isEditMode ? job.editImagePaths : [job.imagePath]
        return (loras + model + images).filter(FileAccessPath.isLocal)
    }

    /// For quantized non-custom models without a published pre-quantized repo, a local
    /// saved copy lets every subsequent load skip in-memory quantization.
    static func quantSaveDestination(job: FluxJob, settings: AppSettings) -> URL? {
        guard job.quantize > 0, job.model != .custom,
              job.model.preQuantizedRepoID(quantize: job.quantize) == nil else { return nil }
        return job.model.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
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

    /// Driver eligibility + request. Edit mode drives a different mflux class,
    /// low-RAM must stream from disk (one-shot by design), custom repos need
    /// `--base-model` semantics the driver doesn't replicate, and FLUX 3's
    /// community repo IDs can't be resolved by the driver at all: its
    /// `_construct_model` calls `ModelConfig.from_name` with no base-model
    /// parameter, so a name matching no alias dies with "Cannot infer
    /// base_model" — and the flux2 branch would load FLUX 3 weights into the
    /// wrong variant class. All four fall back to the CLI subprocess, which
    /// passes `--base-model` explicitly (see `modelArgs`).
    static func driverRequest(job: FluxJob, ctx: JobRunContext, settings: AppSettings) -> DriverGenerateRequest? {
        guard !job.isEditMode, !job.lowRam, job.model != .custom, !job.model.isFlux3 else { return nil }

        // Resolve the model argument exactly like buildArgs: override repo →
        // pre-quantized repo → locally saved weights → base repo (+ in-memory
        // quantize only in the last case).
        var model = job.model.mfluxModelID
        var quantizeArg: Int?
        if let override = settings.defaults(for: job.model).modelRepoOverride, !override.isEmpty {
            model = override
        } else if job.quantize > 0 {
            if let preQuantizedRepo = job.model.preQuantizedRepoID(quantize: job.quantize) {
                model = preQuantizedRepo
            } else {
                let savedPath = job.model.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
                if FluxModelVariant.hasSavedWeights(at: savedPath) {
                    model = savedPath.path
                } else {
                    quantizeArg = job.quantize
                }
            }
        }

        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .flux }
        let loraKey = loras.map { "\($0.path)@\(String(format: "%.2f", $0.strength))" }.joined(separator: ",")
        let outputs: [DriverOutput] = job.seeds.isEmpty
            ? [DriverOutput(seed: ctx.seed, path: ctx.outputFile)]
            : RunnerSupport.expandedPaths(from: ctx.outputFile, seeds: job.seeds)
            .map { DriverOutput(seed: $0.seed, path: $0.path) }

        return DriverGenerateRequest(
            id: job.id.uuidString,
            family: "flux2",
            fingerprint: "flux2|\(model)|q\(quantizeArg ?? 0)|\(loraKey)",
            model: model,
            quantize: quantizeArg,
            loraPaths: loras.map(\.path),
            loraScales: loras.map(\.strength),
            prompt: job.prompt,
            negativePrompt: nil,
            width: job.width,
            height: job.height,
            steps: job.steps,
            guidance: job.guidance,
            imagePath: job.imagePath.isEmpty ? nil : job.imagePath,
            imageStrength: job.imagePath.isEmpty ? nil : job.imageStrength,
            preset: nil,
            strictCaptionValidation: nil,
            cfgEnd: nil,
            pidDecode: job.pidDecode,
            pidDegradeSigma: job.pidDegradeSigma,
            outputs: outputs,
            stepwiseDir: ctx.stepwiseDir.path,
            tePolicy: WarmTextEncoderPolicy.keep.rawValue, // resolved per-run by the controller
            cacheLimitGb: settings.mlxCacheLimitGB,
            modelVariantRaw: job.model.rawValue,
            modelLabel: job.model.displayName
        )
    }

    /// `--pid-decode` when enabled. Split out of `buildArgs` purely to keep that
    /// function under the cyclomatic-complexity limit; the flag only exists on an
    /// mflux that has the decoder, and the toggle is hidden otherwise, so a stale
    /// install cannot smuggle an unrecognised flag into the command line.
    static func pidArgs(pidDecode: Bool, degradeSigma: Double) -> [String] {
        guard pidDecode else { return [] }
        guard degradeSigma > 0 else { return ["--pid-decode"] }
        return ["--pid-decode", "--pid-degrade-sigma", String(format: "%.2f", degradeSigma)]
    }

    /// `--base-model` names the Flux.2 architecture mflux loads a custom checkpoint as, so
    /// a klein-9b fine-tune runs on its own model instead of whatever default the CLI picks.
    /// Probed per interpreter (cached; see ``MfluxProbes/supportsBaseModel(python:)``) rather than
    /// version-gated: package metadata lies on editable installs and no release boundary marks
    /// when the option landed, so ask the parser — pre-option releases reject it with exit 2.
    static func baseModelArgs(base: FluxModelVariant, settings: AppSettings) -> [String] {
        guard MfluxProbes.supportsBaseModel(python: try? settings.toolchain.mfluxInterpreter()) else { return [] }
        return ["--base-model", base.mfluxModelID]
    }

    /// Resolves the `--model` value per job source, in priority order: custom checkpoint,
    /// user override (HF repo ID or local path), published pre-saved community repo —
    /// mflux detects stored_q so no quantize flag rides along; FLUX 3 publishes one at
    /// every precision including BF16, so its gated BFL source is never downloaded by
    /// the app. Then locally saved weights (mflux-save output), finally the bare
    /// registry name for in-memory quantization or unquantized builtins.
    static func modelArgs(job: FluxJob, settings: AppSettings) -> [String] {
        if job.model == .custom {
            // `--model` carries the checkpoint (repo id or local path). `--base-model` names
            // the Flux.2 architecture mflux loads it as — for a fine-tune, `customBaseModel`
            // is that architecture; an mlx-community quantized repo resolves to its family
            // member and keeps this one. Without it the wrong config reached the first
            // attention reshape and crashed. Gated by version via `baseModelArgs`: before
            // 0.19.0 the flag's argparse choices= list rejected klein keys and exited with
            // code 2, so a stale or unreadable install must not see it — which drops back to
            // that mflux's pre-gate behavior rather than failing here.
            let base = job.customBaseModel.family == .flux ? job.customBaseModel : .flux2Klein9B
            if base.isFlux3 {
                // Any runtime with the flux3 CLI is ≥0.23 and accepts --base-model, so pass it
                // unconditionally: a probe-gated flag dropped on a slow interpreter would leave
                // mflux guessing the architecture from a name that matches no alias.
                return ["--model", job.customModelRepo, "--base-model", base.mfluxModelID]
            }
            return ["--model", job.customModelRepo] + baseModelArgs(base: base, settings: settings)
        }

        if let override = settings.defaults(for: job.model).modelRepoOverride, !override.isEmpty {
            // User-supplied override (HF repo ID or local path): use as-is.
            return ["--model", override] + baseModelArgs(base: job.model, settings: settings)
        }

        if let publishedRepo = job.model.preQuantizedRepoID(quantize: job.quantize) {
            // Known pre-saved community repo (mlx-community / mflux-community).
            var args = ["--model", publishedRepo]
            if let baseKey = job.model.baseModelKey {
                // FLUX 3's repo name matches no alias mflux can infer from, so the root config
                // must be named explicitly. Any runtime with the .flux3 tool is ≥0.23 and accepts
                // --base-model — pass it unconditionally: a probe-gated flag silently dropped on a
                // slow interpreter would break every generation with "Cannot infer base_model".
                args += ["--base-model", baseKey]
            } else {
                args += baseModelArgs(base: job.model, settings: settings)
            }
            return args
        }

        if job.quantize > 0 {
            let savedPath = job.model.savedModelPath(quantize: job.quantize, in: settings.effectiveMfluxCacheDir)
            if FluxModelVariant.hasSavedWeights(at: savedPath) {
                // Local mflux-saved weights: pass path directly — mflux detects stored_q,
                // but a bare local path carries no architecture, so name it explicitly.
                return ["--model", savedPath.path] + baseModelArgs(base: job.model, settings: settings)
            }
        }
        // Builtin model with no override or quantization (or mflux-save failed): the
        // registry name — omitting --model would silently fall back to the CLI's default.
        return ["--model", job.model.mfluxModelID]
    }

    static func buildArgs(job: FluxJob, ctx: JobRunContext, settings: AppSettings) -> [String] {
        var args = modelArgs(job: job, settings: settings)
        args += ["--prompt", job.prompt]
        // A custom checkpoint inherits its target's capabilities, so judge prompt and
        // guidance support on the variant that actually runs. FLUX 3 rejects
        // `--negative-prompt` outright (a hard CLI error), unlike every other target.
        let effective = job.model == .custom ? job.customBaseModel : job.model
        let supportsNeg = job.model.supportsNegativePrompt && !(job.model == .custom && effective.isFlux3)
        if supportsNeg, !job.negativePrompt.isEmpty {
            args += ["--negative-prompt", job.negativePrompt]
        }

        args += [
            "--width", "\(job.width)",
            "--height", "\(job.height)",
            "--steps", "\(job.steps)",
        ]
        // FLUX 3's distilled checkpoint has no CFG branch and its CLI warns whenever
        // `--guidance` is supplied — omit it there and let mflux use the model default.
        if effective.supportsGuidance {
            args += ["--guidance", String(format: "%.2f", job.guidance)]
        }
        args += [
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
        if job.lowRam {
            args.append("--low-ram")
        }
        if settings.mlxCacheLimitGB > 0 {
            args += ["--mlx-cache-limit-gb", String(format: "%.1f", settings.mlxCacheLimitGB)]
        }

        if job.isEditMode {
            if !job.editImagePaths.isEmpty {
                args += ["--image-paths"] + job.editImagePaths
            }
        } else if !job.imagePath.isEmpty, !effective.isFlux3 {
            // FLUX 3's txt2img CLI accepts an init image but never reads it — passing one
            // would silently drop the user's reference. The params panel hides img2img for
            // this variant; this drops any stale state that survived a model switch.
            args += [
                "--image-path", job.imagePath,
                "--image-strength", String(format: "%.2f", job.imageStrength),
            ]
        }

        // LoRA entries carry no per-model scope, so a Flux.2 LoRA can remain enabled when
        // the target is FLUX 3 — its layers don't map onto that architecture. Drop it rather
        // than hand mflux weights for the wrong model (same treatment as stale img2img state).
        let enabledLoras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .flux && !effective.isFlux3 }
        if !enabledLoras.isEmpty {
            args += ["--lora-paths"] + enabledLoras.map(\.path)
            args += ["--lora-scales"] + enabledLoras.map { String(format: "%.2f", $0.strength) }
        }

        args += ["--stepwise-image-output-dir", ctx.stepwiseDir.path]

        // Neither FLUX 3 CLI implements PiD decode; the flag would be silently ignored.
        if !effective.isFlux3 {
            args += pidArgs(pidDecode: job.pidDecode, degradeSigma: job.pidDegradeSigma)
        }

        return args
    }
}
