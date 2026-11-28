import Foundation

/// Executes Krea 2 Turbo generation jobs by driving the `mflux-generate-krea2` CLI.
/// The shared ``JobRunner`` engine owns the process lifecycle; this spec supplies the
/// Krea-specific behavior. Every precision loads its `mflux-community/krea-2-turbo-mflux-*`
/// repo directly (see ``FluxModelVariant/publishedRepoID(quantize:)``), unless a legacy
/// mflux-save copy is already on disk.
typealias Krea2JobRunner = JobRunner<Krea2RunnerSpec>

extension Krea2Job: @MainActor QueueListedJob {
    var queueTitle: String {
        prompt
    }
}

enum Krea2RunnerSpec: @MainActor JobRunnerSpec {
    typealias Job = Krea2Job
    typealias Store = Krea2JobStore

    static let family: ModelFamily = .krea2
    static let stepwiseSubdir = "stepwise-krea2"
    static let outputPrefix = "krea2"
    static let encodingLabel = "Generating"

    static func preview(_ job: Krea2Job) -> PreviewState {
        .activeKrea2Job(job)
    }

    static func tool(job _: Krea2Job) -> PythonTool {
        .krea2
    }

    /// Exactly what the run reads: enabled LoRAs of this family, the model folder, and its image.
    static func accessPaths(job: Krea2Job) -> [String] {
        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .krea2 }.map(\.path)
        return (loras + [job.customModelRepo, job.imagePath]).filter(FileAccessPath.isLocal)
    }

    /// img2img runs fewer denoise steps than requested (the image-strength schedule
    /// drops the leading steps), so the tqdm total can be < job.steps. Accept any
    /// genuine tqdm bar up to the requested count, otherwise the UI stays stuck on
    /// "Loading model…" for the whole img2img run.
    static func acceptsProgressTotal(_ total: Int, job: Krea2Job) -> Bool {
        total <= job.steps
    }

    static func timingModelKey(job: Krea2Job) -> String {
        TimingStore.modelKey("krea2", customRepo: job.customModelRepo)
    }

    static func timingLowRam(job: Krea2Job) -> Bool {
        job.lowRam
    }

    static func writeMetadata(job: Krea2Job, seed: Int, startedAt: Date?, generatedAt: Date, path: String) {
        var meta = Krea2Metadata.from(job: job)
        meta.seed = seed
        meta.startedAt = startedAt
        meta.generatedAt = generatedAt
        MetadataSidecar.write(meta, for: path)
    }

    /// A repo ID or path that replaces the stock Krea 2 model source: the picker's
    /// `Custom…` entry first, then the Settings → Models override. Both name a
    /// specific set of weights, so neither takes a `--quantize` pass.
    private static func modelSourceOverride(job: Krea2Job, settings: AppSettings) -> String? {
        let custom = job.customModelRepo.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            return custom
        }
        let override = (settings.defaults(for: .krea2).modelRepoOverride ?? "")
            .trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? nil : override
    }

    /// Resolves the `--model` value and the `--quantize` level that goes with it.
    /// Precedence: custom repo → Settings override → a legacy mflux-saved copy →
    /// the published repo for the precision. Each carries its own quantization, so
    /// `--quantize` rides along only on the registry fallback, which no stock level reaches.
    static func resolveModel(job: Krea2Job, settings: AppSettings) -> (model: String, quantize: Int?) {
        if let source = modelSourceOverride(job: job, settings: settings) {
            return (source, nil)
        }
        let variant = FluxModelVariant.krea2
        if let saved = variant.legacySavedWeights(quantize: job.quantize, in: settings.effectiveMfluxCacheDir) {
            return (saved.path, nil)
        }
        if let repo = variant.publishedRepoID(quantize: job.quantize) {
            return (repo, nil)
        }
        return (variant.mfluxModelID, job.quantize > 0 ? job.quantize : nil)
    }

    /// Driver eligibility + request. Low-RAM jobs stream blocks from disk and
    /// stay on the one-shot CLI (keeping the model resident defeats them); every
    /// other job qualifies. Model resolution mirrors buildArgs.
    static func driverRequest(job: Krea2Job, ctx: JobRunContext, settings: AppSettings) -> DriverGenerateRequest? {
        guard !job.lowRam else { return nil }

        let (model, quantizeArg) = resolveModel(job: job, settings: settings)

        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .krea2 }
        let trimmedNegative = job.negativePrompt.trimmingCharacters(in: .whitespaces)

        return DriverGenerateRequest(
            id: job.id.uuidString,
            family: "krea2",
            fingerprint: "krea2|\(model)|q\(quantizeArg ?? 0)|\(RunnerSupport.driverLoraKey(loras))",
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
            pidDecode: job.pidDecode,
            pidDegradeSigma: job.pidDegradeSigma,
            outputs: RunnerSupport.driverOutputs(ctx: ctx, seeds: job.seeds),
            stepwiseDir: ctx.stepwiseDir.path,
            tePolicy: WarmTextEncoderPolicy.keep.rawValue, // resolved per-run by the controller
            cacheLimitGb: settings.mlxCacheLimitGB,
            modelVariantRaw: FluxModelVariant.krea2.rawValue,
            selectionKey: ModelSelection(variant: .krea2, quantize: job.quantize, customRepo: job.customModelRepo).key
        )
    }

    /// Remote Krea 2 graph from the bundled templates: the t2i or i2i flow (by source-image presence), the job's
    /// params and the per-family model files from Settings injected through the param map, and the enabled LoRA
    /// chain inserted dynamically. Krea 2's fp8 pipeline loads three files; all must be configured to route
    /// remote, otherwise the job runs on local mflux.
    static func comfyGraph(job: Krea2Job, settings: AppSettings, client: ComfyUIClient) async throws -> ComfyGraph? {
        let id = family.id
        guard settings.comfyFiles(key: id) != nil else { return nil }

        let key = job.imagePath.isEmpty ? "krea2/t2i" : "krea2/i2i"
        let template = try ComfyTemplate.load(familyFlowKey: key)
        let map = try ComfyParamMap.load(familyFlowKey: key)
        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .krea2 }.map {
            ComfyLora(name: resolverServerLoraName($0.path), strength: $0.strength)
        }
        var params = krea2Params(job: job, settings: settings, familyID: id)
        // i2i only: upload the source once and reuse the server filename across seeds. A failed upload throws and
        // fails the job — there is no silent t2i fallback.
        if !job.imagePath.isEmpty {
            params["source_image"] = try await client.uploadImage(localPath: job.imagePath)
        }
        // Render once (seed 0, the old builder's convention): a stale param map throws here and fails the job
        // loudly instead of per seed. The per-seed closure then swaps only the KSampler seed.
        let base = try template.render(map: map, params: params, loras: loras)
        return .seeded(base, map: map, totalSteps: job.steps)
    }

    /// The param-map values for one Krea 2 job: its prompt/size/steps plus the per-family model files from
    /// Settings (which override the template's baked filenames). `seed` is 0 here; the per-seed closure swaps it.
    static func krea2Params(job: Krea2Job, settings: AppSettings, familyID: String) -> [String: Any] {
        let isT2i = job.imagePath.isEmpty
        var params: [String: Any] = [
            "prompt": job.prompt,
            "seed": 0, // set per seed by the render closure
            "steps": job.steps,
            "cfg": job.guidance,
            "sampler": "euler",
            "scheduler": "simple", // matches mflux's Krea2 spacing; "normal" wastes its last step on flow models
            // i2i: "image strength" = image preservation (high = keep the source), so denoise is the
            // INVERSE — the mflux CLI maps --image-strength 0.9 to denoise 0.1, and KSampler denoise
            // 1.0 = full re-gen, 0.0 = unchanged.
            "denoise": isT2i ? 1.0 : 1.0 - job.imageStrength,
            "unet_name": settings.comfyUNet[familyID] ?? "",
            "clip_name": settings.comfyClip[familyID] ?? "",
            "vae_name": settings.comfyVae[familyID] ?? "",
            // The param map targets SaveImage's filename_prefix, which must be `mlxbits/<family>`: ComfyUI's
            // get_save_image_path does dirname(prefix)→subfolder, basename(prefix)→filename, and a bare "mlxbits"
            // drops the file in the output ROOT. A single slash is required; it cannot nest.
            "save_subfolder": "mlxbits/\(familyID)",
        ]
        // The i2i template has no size node (output follows the source), so width/height are t2i-only.
        if isT2i {
            params["width"] = job.width
            params["height"] = job.height
        }
        return params
    }

    static func buildArgs(job: Krea2Job, ctx: JobRunContext, settings: AppSettings) -> [String] {
        var args: [String] = []

        let (model, quantizeArg) = resolveModel(job: job, settings: settings)
        args += ["--model", model]

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

        // Only the registry fallback quantizes in memory; every published repo is pre-quantized.
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

        let enabledLoras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .krea2 }
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
