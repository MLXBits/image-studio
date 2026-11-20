import Foundation

/// Executes Qwen-Image 2.1 Turbo jobs through `mflux-generate-qwen-2.1-edit`,
/// which does text-to-image with no references and multi-reference editing
/// with them. Weights load straight from the mflux-community repo for the
/// chosen precision (BF16, Q8, Q4): there is no `mflux-save` pass and no
/// `--quantize`. With Keep Model Warm on, jobs run on the warm driver except
/// low-RAM ones, which stay on the one-shot CLI.
typealias Qwen21JobRunner = JobRunner<Qwen21RunnerSpec>

extension Qwen21Job: @MainActor QueueListedJob {
    var queueTitle: String {
        prompt
    }
}

extension Qwen21JobStore: @MainActor GenerationJobStore {}

enum Qwen21RunnerSpec: @MainActor JobRunnerSpec {
    typealias Job = Qwen21Job
    typealias Store = Qwen21JobStore

    static let family: ModelFamily = .qwen21
    static let stepwiseSubdir = "stepwise-qwen21"
    static let outputPrefix = "qwen21"
    static let encodingLabel = "Generating"
    /// The `comfyClip` key for the prompt enhancer's CLIP, beside the family's own encoder entry.
    static let enhancerClipKey = "qwen21.enhancer"
    /// The size the encoder resizes each reference to, keeping its aspect ratio: mflux's `output_resolution`.
    static let referenceResolution = 1024
    /// Turbo's 8-step sigma schedule, as the bundled ComfyUI templates carry it.
    static let turboSigmas = [1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568, 0]

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
        MetadataSidecar.write(meta, for: path)
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
            enhancePrompt: job.enhancePrompt ? true : nil,
            outputs: RunnerSupport.driverOutputs(ctx: ctx, seeds: job.seeds),
            stepwiseDir: "", // no previews, as in buildArgs
            tePolicy: WarmTextEncoderPolicy.keep.rawValue,
            cacheLimitGb: settings.mlxCacheLimitGB,
            modelVariantRaw: variant.rawValue,
            modelLabel: RunnerSupport.modelLabel(custom: job.customModelRepo, fallback: variant.displayName)
        )
    }

    /// Local mflux enhances only edits: it rewrites the instruction against the references with the Qwen3-VL
    /// text encoder it already holds. ComfyUI's template enhancer also covers Generate.
    static func canEnhanceLocally(job: Qwen21Job) -> Bool {
        job.isEditMode && !job.editImagePaths.isEmpty
    }

    /// A Generate job queued for ComfyUI's enhancer can still run locally if Settings changed meanwhile.
    static func willRunLocally(job: Qwen21Job) {
        if job.enhancePrompt, !canEnhanceLocally(job: job) {
            job.enhancePrompt = false
            job.log += "Enhance prompt skipped: local mflux enhances only edits.\n"
        }
    }

    // MARK: - ComfyUI remote routing

    /// Remote graph from the bundled t2i or edit template. The UNet, CLIP and VAE files must all be set in
    /// Settings, else the job runs on local mflux. With Enhance prompt on, the template's enhancer rewrites the
    /// prompt first; off, the enhancer branch is pruned and the prompt goes straight to the encoder.
    static func comfyGraph(job: Qwen21Job, settings: AppSettings, client: ComfyUIClient) async throws -> ComfyGraph? {
        guard let files = comfyFiles(settings: settings) else { return nil }
        let enhancerClip = settings.comfyClip[enhancerClipKey] ?? ""
        if job.enhancePrompt, enhancerClip.isEmpty {
            throw Qwen21ComfyGraphError.noEnhancerClip
        }

        let refs = job.isEditMode ? job.editImagePaths : []
        let key = refs.isEmpty ? "qwen21/t2i" : "qwen21/edit"
        let template = try ComfyTemplate.load(familyFlowKey: key)
        let map = try ComfyParamMap.load(familyFlowKey: key)
        var params: [String: Any] = [
            "seed": 0, // set per seed by the render closure
            "sigmas": comfySigmas(steps: job.steps),
            "width": job.width,
            "height": job.height,
            "unet_name": files[0],
            "clip_name": files[1],
            "vae_name": files[2],
            // SaveImage's prefix must be `mlxbits/<family>`: ComfyUI splits it into subfolder + filename.
            "save_subfolder": "mlxbits/\(outputPrefix)",
        ]
        if job.enhancePrompt {
            params["enhance_prompt"] = job.prompt
            params["pe_clip_name"] = enhancerClip
        } else {
            params["encoder_prompt"] = job.prompt
        }
        // Upload once and reuse the server filenames across seeds. A failed upload fails the job.
        var uploaded: [String] = []
        for path in refs {
            try await uploaded.append(client.uploadImage(localPath: path))
        }
        if let first = uploaded.first {
            // ComfyUI's encoder sizes its own latent from the FIRST reference; mflux sizes from the last. The
            // app sizes the edit the mflux way and always samples the empty latent at that size.
            let size = try editSize(job: job)
            params["source_image"] = first
            params["custom_size"] = true
            params["width"] = size.width
            params["height"] = size.height
            params["reference_resolution"] = referenceResolution
        }
        let loras = enabledLoras(job).map { ComfyLora(name: resolverServerLoraName($0.path), strength: $0.strength) }
        var graph = try template.render(map: map, params: params, loras: loras)
        try addReferences(&graph, names: uploaded.dropFirst(), map: map)
        if !job.enhancePrompt {
            comfyPruneUnreachable(&graph)
        }
        return .seeded(graph, map: map, totalSteps: job.steps)
    }

    /// The UNet, CLIP and VAE files from Settings, or nil when any is unset (the job then runs locally).
    static func comfyFiles(settings: AppSettings) -> [String]? {
        let id = family.id
        let files = [settings.comfyUNet[id], settings.comfyClip[id], settings.comfyVae[id]].map { $0 ?? "" }
        return files.contains(where: \.isEmpty) ? nil : files
    }

    /// A Qwen job runs on ComfyUI: the backend segment is set, there's a server URL, and all three files are set.
    static func routesToComfy(settings: AppSettings) -> Bool {
        settings.comfyBackendEnabled[family.id] == true
            && !settings.comfyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && comfyFiles(settings: settings) != nil
    }

    /// An edit's output size. Following the references uses mflux's rule: the last reference's aspect ratio at
    /// about 1024², in multiples of 32, so a lone reference encodes at exactly the latent's size. A chosen size
    /// with another aspect ratio can shift the edit, as on local mflux, which also keeps each reference's shape.
    static func editSize(job: Qwen21Job) throws -> (width: Int, height: Int) {
        func snap(_ value: Double) -> Int {
            max(32, Int((value / 32).rounded()) * 32)
        }
        guard job.followsReferenceSize else {
            return (job.width, job.height)
        }
        guard let last = job.editImagePaths.last, let (w, h) = imagePixelSize(at: last), w > 0, h > 0 else {
            throw Qwen21ComfyGraphError.unreadableReference
        }
        let ratio = Double(w) / Double(h)
        let side = Double(referenceResolution)
        let width = (side * side * ratio).squareRoot()
        return (snap(width), snap(width / ratio))
    }

    /// The ManualSigmas value for `steps`: the 8-step schedule as is, else resampled linearly to steps + 1 points.
    static func comfySigmas(steps: Int) -> String {
        let last = Double(turboSigmas.count - 1)
        let count = max(steps, 1)
        return (0 ... count).map { i in
            let x = Double(i) * last / Double(count)
            let lo = min(Int(x), turboSigmas.count - 2)
            let sigma = turboSigmas[lo] + (turboSigmas[lo + 1] - turboSigmas[lo]) * (x - Double(lo))
            return String(format: "%g", sigma)
        }.joined(separator: ", ")
    }

    /// Edit references 2…N: a LoadImage each, wired into the encoder's `images.image_<n>` and the enhancer's
    /// `images.image<n>`. Separate enhancer inputs, not a batch: batching crops every image to the first one's shape.
    private static func addReferences(_ graph: inout [String: Any], names: ArraySlice<String>, map: ComfyParamMap) throws {
        guard !names.isEmpty else { return }
        guard let load = map.params["source_image"]?.node, let loadNode = graph[load] as? [String: Any],
              let encoder = map.params["encoder_prompt"]?.node, let enhancer = map.params["enhance_prompt"]?.node
        else { throw ComfyTemplateError.missingNode("LoadImage/TextEncodeQwenImage21/TextGenerateV2") }
        for (offset, name) in names.enumerated() {
            let n = offset + 2 // reference 1 is the template's own LoadImage
            var node = loadNode
            node["inputs"] = ["image": name]
            graph["ref_\(n)"] = node
            comfySetInput(&graph, node: encoder, input: "images.image_\(n)", value: ["ref_\(n)", 0])
            // The enhancer is pruned afterwards when it's off.
            comfySetInput(&graph, node: enhancer, input: "images.image\(n)", value: ["ref_\(n)", 0])
        }
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
            if job.enhancePrompt {
                args.append("--enhance-prompt")
            }
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

/// A Qwen-Image 2.1 remote job the bundled templates can't run.
enum Qwen21ComfyGraphError: LocalizedError, Equatable {
    case noEnhancerClip
    /// The last reference's pixel size, which sizes the edit, couldn't be read.
    case unreadableReference

    var errorDescription: String? {
        switch self {
        case .noEnhancerClip:
            "Enhance prompt needs the prompt enhancer's CLIP file, set in Settings ▸ Models ▸ Qwen-Image 2.1 Turbo."
        case .unreadableReference:
            "Couldn't read the last reference image's size, which sets the edit's size."
        }
    }
}
