import Foundation

/// Executes FLUX generation jobs by driving the `mflux-generate-flux2` /
/// `mflux-generate-flux2-edit` CLI. The shared ``JobRunner`` engine owns the
/// process lifecycle; this spec supplies the FLUX-specific behavior.
typealias FluxJobRunner = JobRunner<FluxRunnerSpec>

extension FluxJob: @MainActor GeneratedJob {}

extension FluxJob: @MainActor QueueListedJob {
    var queueTitle: String {
        prompt
    }
}

/// Where a job's weights come from, which decides its `--model` value and whether
/// `--base-model` rides along. Chosen once by ``FluxRunnerSpec/modelRoute(job:settings:)`` for both
/// ``FluxRunnerSpec/modelArgs(job:settings:python:)`` and ``FluxRunnerSpec/prepareArgs(job:settings:python:)``.
enum FluxModelRoute: Equatable {
    /// A custom checkpoint (repo id or local path), loaded as `base`.
    case custom(repo: String, base: FluxModelVariant)
    /// The user's repo override (HF repo ID or local path) for `model`.
    case override(String)
    /// A published pre-saved community repo; `baseKey` names its root config when the
    /// repo name matches no alias mflux can infer from (FLUX 3).
    case published(repo: String, baseKey: String?)
    /// A legacy mflux-saved copy (see ``FluxModelVariant/legacySavedWeights(quantize:in:)``).
    case saved(URL)
    /// The bare registry name, quantized in memory. No stock level reaches it: each has a
    /// published repo.
    case registry

    /// Whether the route sends `--base-model` only when the probe says mflux accepts it.
    /// FLUX 3 routes pass it unconditionally, and the registry name never passes it.
    var needsBaseModelProbe: Bool {
        switch self {
        case let .custom(_, base): !base.isFlux3
        case .override, .saved: true
        case let .published(_, baseKey): baseKey == nil
        case .registry: false
        }
    }
}

enum FluxRunnerSpec: @MainActor JobRunnerSpec {
    typealias Job = FluxJob
    typealias Store = JobStore

    static let family: ModelFamily = .flux
    static let stepwiseSubdir = "stepwise"
    static let outputPrefix = "image"
    static let encodingLabel = "Encoding prompt"
    /// The max reference images the bundled i2e templates accept (their LoadImage slots).
    static let maxEditRefs = 6

    static func preview(_ job: FluxJob) -> PreviewState {
        .activeJob(job)
    }

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

        // Resolve the model argument exactly like buildArgs (``modelRoute``), with the
        // in-memory quantize only on the registry fallback.
        let route = modelRoute(job: job, settings: settings)
        let model: String = switch route {
        case let .override(override): override
        case let .published(repo, _): repo
        case let .saved(path): path.path
        case .custom, .registry: job.model.mfluxModelID
        }
        let quantizeArg = inMemoryQuantize(route: route, job: job)

        let loras = job.loras.filter { $0.enabled && $0.isValid && $0.modelFamily == .flux }

        return DriverGenerateRequest(
            id: job.id.uuidString,
            family: "flux2",
            fingerprint: "flux2|\(model)|q\(quantizeArg ?? 0)|\(RunnerSupport.driverLoraKey(loras))",
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
            outputs: RunnerSupport.driverOutputs(ctx: ctx, seeds: job.seeds),
            stepwiseDir: ctx.stepwiseDir.path,
            tePolicy: WarmTextEncoderPolicy.keep.rawValue, // resolved per-run by the controller
            cacheLimitGb: settings.mlxCacheLimitGB,
            modelVariantRaw: job.model.rawValue,
            selectionKey: job.selection.key
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
    ///
    /// Uses the answer the job's run awaited (``JobRunContext/baseModelSupported``) rather than
    /// re-reading a cache that a probe reset during the wait may have invalidated; a route that
    /// never asked the probe (nil) leaves the flag off as on a pre-option mflux.
    static func baseModelArgs(base: FluxModelVariant, baseModelSupported: Bool?) -> [String] {
        guard baseModelSupported == true else { return [] }
        return ["--base-model", base.mfluxModelID]
    }

    /// Awaits the `--base-model` probe off the main actor (keyed on the run's captured
    /// `python`) and returns its answer for ``JobRunContext/baseModelSupported``. Returns nil
    /// for a route that never asks the probe (see ``FluxModelRoute/needsBaseModelProbe``).
    /// Usually instant otherwise: the probe is warmed at launch and whenever the interpreter
    /// changes (``AppSettings/refreshToolchain()``).
    static func prepareArgs(job: FluxJob, settings: AppSettings, python: String?) async -> Bool? {
        guard modelRoute(job: job, settings: settings).needsBaseModelProbe else { return nil }
        return await MfluxProbes.supportsBaseModel(python: python)
    }

    /// Picks the job's ``FluxModelRoute`` in priority order: custom checkpoint, user override,
    /// a legacy mflux-saved copy (so nobody downloads a model twice), the published
    /// mflux-community repo, and finally the bare registry name.
    static func modelRoute(job: FluxJob, settings: AppSettings) -> FluxModelRoute {
        if job.model == .custom {
            // For a fine-tune, `customBaseModel` is the architecture; an mlx-community quantized
            // repo resolves to its family member and keeps this one.
            let base = job.customBaseModel.family == .flux ? job.customBaseModel : .flux2Klein9B
            return .custom(repo: job.customModelRepo, base: base)
        }
        if let override = settings.defaults(for: job.model).modelRepoOverride, !override.isEmpty {
            return .override(override)
        }
        if let saved = job.model.legacySavedWeights(quantize: job.quantize, in: settings.effectiveMfluxCacheDir) {
            return .saved(saved)
        }
        if let publishedRepo = job.model.publishedRepoID(quantize: job.quantize) {
            return .published(repo: publishedRepo, baseKey: job.model.baseModelKey)
        }
        return .registry
    }

    /// The `--quantize` level for in-memory quantization: a custom checkpoint and the registry
    /// fallback take one. Overrides, published repos and saved copies carry stored_q in their metadata.
    static func inMemoryQuantize(route: FluxModelRoute, job: FluxJob) -> Int? {
        guard job.quantize > 0 else { return nil }
        switch route {
        case .custom, .registry: return job.quantize
        case .override, .published, .saved: return nil
        }
    }

    /// Resolves the `--model` value for the job's ``FluxModelRoute``: mflux detects stored_q on
    /// a pre-saved repo or saved weights, so no quantize flag rides along; FLUX 3 publishes
    /// one at every precision including BF16, so its gated BFL source is never downloaded by
    /// the app.
    static func modelArgs(job: FluxJob, settings: AppSettings, baseModelSupported: Bool?) -> [String] {
        switch modelRoute(job: job, settings: settings) {
        case let .custom(repo, base):
            // `--model` carries the checkpoint. `--base-model` names the Flux.2 architecture
            // mflux loads it as: without it the wrong config reached the first attention
            // reshape and crashed. Gated by the probe via `baseModelArgs`: before 0.19.0 the
            // flag's argparse choices= list rejected klein keys and exited with code 2, so a
            // stale or unreadable install must not see it — which drops back to that mflux's
            // pre-gate behavior rather than failing here.
            if base.isFlux3 {
                // Any runtime with the flux3 CLI is ≥0.23 and accepts --base-model, so pass it
                // unconditionally: a probe-gated flag dropped on a slow interpreter would leave
                // mflux guessing the architecture from a name that matches no alias.
                return ["--model", repo, "--base-model", base.mfluxModelID]
            }
            return ["--model", repo] + baseModelArgs(base: base, baseModelSupported: baseModelSupported)
        case let .override(override):
            return ["--model", override] + baseModelArgs(base: job.model, baseModelSupported: baseModelSupported)
        case let .published(repo, baseKey):
            if let baseKey {
                // FLUX 3's repo name matches no alias mflux can infer from, so the root config
                // must be named explicitly. Any runtime with the .flux3 tool is ≥0.23 and accepts
                // --base-model — pass it unconditionally: a probe-gated flag silently dropped on a
                // slow interpreter would break every generation with "Cannot infer base_model".
                return ["--model", repo, "--base-model", baseKey]
            }
            return ["--model", repo] + baseModelArgs(base: job.model, baseModelSupported: baseModelSupported)
        case let .saved(savedPath):
            // A bare local path carries no architecture, so name it explicitly.
            return ["--model", savedPath.path] + baseModelArgs(base: job.model, baseModelSupported: baseModelSupported)
        case .registry:
            // Omitting --model would silently fall back to the CLI's default.
            return ["--model", job.model.mfluxModelID]
        }
    }

    static func buildArgs(job: FluxJob, ctx: JobRunContext, settings: AppSettings) -> [String] {
        var args = modelArgs(job: job, settings: settings, baseModelSupported: ctx.baseModelSupported)
        args += ["--prompt", job.prompt]
        // A custom checkpoint inherits its target's capabilities, so judge prompt and
        // guidance support on the variant that actually runs. FLUX 3 rejects
        // `--negative-prompt` outright (a hard CLI error), unlike every other target.
        let effective = job.model == .custom ? job.customBaseModel : job.model
        if job.model.sendsNegativePrompt(loadsAs: effective), !job.negativePrompt.isEmpty {
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

        if let quantize = inMemoryQuantize(route: modelRoute(job: job, settings: settings), job: job) {
            args += ["--quantize", "\(quantize)"]
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

    // MARK: - ComfyUI remote routing (FLUX.2)

    /// The FLUX.2 ComfyUI flow key for a variant + mode — `flux2/<size>-<flow>-<variant>`
    /// (e.g. `flux2/4b-i2e-distilled`) — or nil when the variant has no bundled FLUX.2 template
    /// (FLUX.3 is a separate workstream; the other families have none at all).
    static func flux2FlowKey(variant: FluxModelVariant, hasRefs: Bool) -> String? {
        guard variant.isFlux2 else { return nil }
        let size = variant.rawValue.contains("4b") ? "4b" : "9b"
        let kind = variant.rawValue.contains("base") ? "base" : "distilled"
        return "flux2/\(size)-\(hasRefs ? "i2e" : "t2i")-\(kind)"
    }

    /// Remote FLUX.2 graph from the bundled templates: the t2i or i2e flow (by reference presence), the job's
    /// params and the per-variant model files from Settings injected through the param map, and the enabled
    /// LoRA chain inserted dynamically. FLUX.2's pipeline loads three files; all must be configured to route
    /// remote, otherwise the job runs on local mflux. FLUX.3 (and custom checkpoints targeting it) is a
    /// separate workstream. A failed source-image upload or a stale param map throws and fails the job —
    /// there is no silent local fallback.
    static func comfyGraph(job: FluxJob, settings: AppSettings, client: ComfyUIClient) async throws -> ComfyGraph? {
        // Custom checkpoints run as their target variant (as `buildArgs` does), so the template and the
        // model-file settings follow the target.
        let variant = job.model == .custom ? job.customBaseModel : job.model
        // Reference selection follows the job's edit mode, exactly like `buildArgs`/`accessPaths`: edit mode
        // uses `editImagePaths`; otherwise the single `imagePath` (i2i). Stale state left in the inactive
        // mode's field must not affect routing.
        let refs: [String] = job.isEditMode
            ? job.editImagePaths
            : (job.imagePath.isEmpty ? [] : [job.imagePath])
        let hasRefs = !refs.isEmpty
        guard let key = flux2FlowKey(variant: variant, hasRefs: hasRefs) else { return nil }
        let variantID = variant.rawValue
        // The model-file gate runs before the reference-count check: when remote routing is enabled but the
        // variant's files are incomplete, the job falls back to local mflux (the documented behavior) instead
        // of failing on an over-limit ref count.
        guard settings.comfyFiles(key: variantID) != nil else { return nil }
        // Shape check after the file gate: the i2e templates carry exactly `maxEditRefs` LoadImage slots.
        if refs.count > maxEditRefs {
            throw FluxComfyGraphError.tooManyReferences(got: refs.count, max: maxEditRefs)
        }

        let template = try ComfyTemplate.load(familyFlowKey: key)
        let map = try ComfyParamMap.load(familyFlowKey: key)
        var params = flux2Params(job: job, settings: settings, variant: variant, hasRefs: hasRefs)
        // i2e only: upload the source(s) once and reuse the server filenames across seeds. A failed upload
        // throws and fails the job — there is no silent t2i fallback.
        if hasRefs {
            for (index, path) in refs.enumerated() {
                params[index == 0 ? "source_image" : "source_image_\(index)"] = try await client.uploadImage(localPath: path)
            }
        }
        // Render once (seed 0, the Krea 2 convention): a stale param map throws here and fails the job
        // loudly instead of per seed. The per-seed closure then swaps only the noise seed.
        let loras = flux2Loras(job.loras)
        let rendered = try template.render(map: map, params: params, loras: loras, loraKind: .full)
        // i2e only: excise the unused conditioning slots so the graph carries exactly the user's reference
        // count. A LoadImage with no image input fails at runtime, so the unused slots are removed and the
        // kept chains rewired before submission. t2i templates have no reference slots (hasRefs is false),
        // so this is skipped there and the Krea 2 path is untouched.
        let base: [String: Any]
        if hasRefs {
            let refCount = refs.count
            var excised = rendered
            try exciseUnusedConditioningSlots(&excised, keepCount: refCount, slotOrder: map.referenceSlotOrder)
            base = excised
        } else {
            base = rendered
        }
        return .seeded(base, map: map, totalSteps: job.steps)
    }

    /// The param-map values for one FLUX.2 job: its prompt/size/steps plus the per-variant model files from
    /// Settings (which override the template's baked filenames). `seed` is 0 here; the per-seed closure swaps
    /// it. Distilled variants run at cfg 1 (no CFG branch); Base uses the job's guidance. width/height ride
    /// only on t2i — the i2e templates derive size from the reference.
    static func flux2Params(job: FluxJob, settings: AppSettings, variant: FluxModelVariant, hasRefs: Bool) -> [String: Any] {
        let variantID = variant.rawValue
        var params: [String: Any] = [
            "prompt": job.prompt,
            "seed": 0, // set per seed by the render closure
            "steps": job.steps,
            "cfg": variant.isDistilled ? 1.0 : job.guidance,
            "sampler": "euler",
            "unet_name": settings.comfyUNet[variantID] ?? "",
            "clip_name": settings.comfyClip[variantID] ?? "",
            "vae_name": settings.comfyVae[variantID] ?? "",
            // The param map targets SaveImage's filename_prefix, which must be `mlxbits/<family>`: ComfyUI's
            // get_save_image_path does dirname(prefix)→subfolder, basename(prefix)→filename, and a bare
            // "mlxbits" drops the file in the output ROOT. A single slash is required; it cannot nest.
            "save_subfolder": "mlxbits/flux2",
        ]
        // The i2e templates have no size node (output follows the reference), so width/height are t2i-only.
        if !hasRefs {
            params["width"] = job.width
            params["height"] = job.height
        }
        return params
    }

    /// The LoRAs to chain into the remote graph: enabled, valid, and `.flux` family (the FLUX.2
    /// architecture), each local path reduced to the server-side filename.
    static func flux2Loras(_ loras: [LoraEntry]) -> [ComfyLora] {
        loras
            .filter { $0.enabled && $0.isValid && $0.modelFamily == .flux }
            .map { ComfyLora(name: resolverServerLoraName($0.path), strength: $0.strength) }
    }
}

/// A FLUX.2 remote job that doesn't fit the bundled templates.
enum FluxComfyGraphError: LocalizedError, Equatable {
    /// More reference images than the i2e template's LoadImage slots.
    case tooManyReferences(got: Int, max: Int)

    var errorDescription: String? {
        switch self {
        case let .tooManyReferences(got, max):
            "FLUX.2 remote editing supports at most \(max) reference images; this job has \(got)."
        }
    }
}

private extension FluxModelVariant {
    /// The four FLUX.2 variants that have bundled ComfyUI templates (the FLUX family minus FLUX.3).
    var isFlux2: Bool {
        isFlux && !isFlux3
    }
}
