import Foundation

enum FluxModelVariant: String, CaseIterable, Codable, Hashable {
    case flux2Klein4B = "flux2-klein-4b"
    case flux2Klein9B = "flux2-klein-9b"
    case flux2KleinBase4B = "flux2-klein-base-4b"
    case flux2KleinBase9B = "flux2-klein-base-9b"
    case flux3Klein = "flux3-image-klein"
    case flux3KleinBase = "flux3-image-klein-base"
    case ideogram4
    case krea2
    case zimageTurbo = "z-image-turbo"
    case zimage = "z-image"
    case qwen21Turbo = "qwen-image-2.1-turbo"
    case custom

    /// Flux.2 variants only — used for base-model pickers and LoRA sections.
    static var builtIn: [Self] {
        [.flux2Klein9B, .flux2Klein4B, .flux2KleinBase9B, .flux2KleinBase4B]
    }

    /// All non-custom models shown in Settings → Models. FLUX 3 first: it is the
    /// newest model and the one users will be looking for.
    static var allModels: [Self] {
        [.flux3Klein, .flux3KleinBase] + builtIn + [.ideogram4, .krea2, .qwen21Turbo, .zimageTurbo, .zimage]
    }

    /// Models the `custom` picker entry can load through: every variant the app
    /// has a params panel for, minus any whose tool the toolchain can't run.
    /// A custom checkpoint is run by its target family's runner, so the target
    /// must be one this toolchain can actually spawn.
    static func customTargets(toolchain: Toolchain) -> [Self] {
        allModels.filter { model in model.generateTool.map(toolchain.hasTool) ?? true }
    }

    /// Returns true if the HF hub model directory is fully downloaded. mflux's own
    /// answer decides when there is a current one (``HFCacheVerdictStore``, #19).
    /// Until then, a quick check: no in-flight `.incomplete` blobs, and a real
    /// multi-GB weight payload (not a metadata-only partial where only
    /// configs/tokenizer came down — e.g. a gated repo whose LFS weights were
    /// blocked, which leaves no `.incomplete` marker).
    static func isCompleteHFCache(at dirURL: URL, verdicts: HFCacheVerdictStore = .shared) -> Bool {
        if let complete = verdicts.isComplete(dirURL) {
            return complete
        }
        let blobsURL = dirURL.appendingPathComponent("blobs")
        guard let blobs = try? FileManager.default.contentsOfDirectory(atPath: blobsURL.path),
              !blobs.isEmpty else { return false }
        if blobs.contains(where: { $0.hasSuffix(".incomplete") }) {
            return false
        }
        // Every supported model's weights are multiple GB; a config-only partial is ~tens of MB.
        return ModelDownloadStore.blobBytes(in: dirURL) > 1_073_741_824
    }

    /// Returns true if mflux-saved weights exist at the given path.
    /// mflux-save writes component subdirectories (transformer/, text_encoder/, vae/, tokenizer/)
    /// each containing .safetensors files, so we check one level deep.
    static func hasSavedWeights(at url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return false }
        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            if ext == "safetensors" {
                return true
            }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir,
               let sub = try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil),
               sub.contains(where: { $0.pathExtension.lowercased() == "safetensors" }) {
                return true
            }
        }
        return false
    }

    var isIdeogram4: Bool {
        self == .ideogram4
    }

    var isKrea2: Bool {
        self == .krea2
    }

    /// Both Z-Image variants (base + distilled Turbo). They share the ``.zimage``
    /// ``ModelFamily`` and one generation pipeline.
    var isZImage: Bool {
        self == .zimageTurbo || self == .zimage
    }

    /// The distilled/guidance-free Z-Image Turbo specifically.
    var isZImageTurbo: Bool {
        self == .zimageTurbo
    }

    var isQwen21: Bool {
        self == .qwen21Turbo
    }

    var isFlux: Bool {
        !isIdeogram4 && !isKrea2 && !isZImage && !isQwen21 && self != .custom
    }

    nonisolated var displayName: String {
        switch self {
        case .flux2Klein4B: "FLUX.2 Klein 4B"
        case .flux2Klein9B: "FLUX.2 Klein 9B"
        case .flux2KleinBase4B: "FLUX.2 Klein Base 4B"
        case .flux2KleinBase9B: "FLUX.2 Klein Base 9B"
        case .ideogram4: "Ideogram 4"
        case .krea2: "Krea 2 Turbo"
        case .zimageTurbo: "Z-Image Turbo"
        case .zimage: "Z-Image"
        case .qwen21Turbo: "Qwen Image 2.1 Turbo"
        case .flux3Klein: "FLUX.3 Klein"
        case .flux3KleinBase: "FLUX.3 Klein Base"
        case .custom: "Custom Model"
        }
    }

    /// Guidance-distilled: guidance is fixed at 1.0 and the field is hidden. Krea 2 Turbo is
    /// step-distilled but keeps CFG for its negative prompt, so it is not one — see ``isStepDistilled``.
    var isDistilled: Bool {
        self == .flux2Klein4B || self == .flux2Klein9B || self == .zimageTurbo || self == .flux3Klein || self == .qwen21Turbo
    }

    /// Step-distilled (a turbo few-step checkpoint): what Settings → Models labels "Distilled".
    var isStepDistilled: Bool {
        isDistilled || self == .krea2
    }

    /// Both FLUX 3 Image Klein variants. They share the `.flux` pipeline but run
    /// through their own mflux CLI (`mflux-generate-flux3[-edit]`) and have no
    /// img2img mode — only text-to-image and multi-reference editing.
    var isFlux3: Bool {
        self == .flux3Klein || self == .flux3KleinBase
    }

    var defaultSteps: Int {
        switch self {
        case .ideogram4: 20 // Normal preset (not directly used — preset drives step count)
        case .krea2: 8 // turbo reference default
        case .zimageTurbo: 9 // mflux z-image-turbo default
        case .zimage: 50 // mflux z-image default
        case .qwen21Turbo: 8 // distilled; the checkpoint ships an 8-sigma schedule
        case .flux3Klein: 16 // distilled Klein is designed for ~16 steps (mflux default)
        default: isDistilled ? 4 : 50 // flux3KleinBase lands here at 50, its CFG default
        }
    }

    /// Upper bound of the Steps field for this model's family.
    var maxSteps: Int {
        switch self {
        case .krea2, .qwen21Turbo: 50
        case .zimage, .zimageTurbo: 100
        default: 150
        }
    }

    var defaultGuidance: Double {
        switch self {
        case .ideogram4: 7.0 // not used by Ideogram4 runner
        case .krea2: 1.0 // turbo reference (CFG 1.0)
        case .zimageTurbo: 1.0 // guidance-free turbo (model forces guidance 0)
        case .zimage: 3.5 // base model classifier-free guidance
        default: isDistilled ? 1.0 : 3.5
        }
    }

    var supportsNegativePrompt: Bool {
        self == .custom || self == .zimage
    }

    /// FLUX 3's distilled checkpoint has no CFG branch; its CLI warns whenever
    /// `--guidance` is supplied, so the runner omits it for that variant and lets
    /// mflux use the model's own default. The Base (undistilled) checkpoint takes
    /// guidance as usual (mflux defaults it to 3.5).
    var supportsGuidance: Bool {
        self != .flux3Klein
    }

    /// Soft cap (in estimated tokens) for the prompt field, or `nil` to hide the
    /// counter. FLUX.2 Klein encodes prompts with Qwen at
    /// `max_sequence_length=512`; text beyond that is truncated by the backend
    /// before it reaches the model. Ideogram routes through its own params panel;
    /// `custom` has an unknown encoder.
    var promptTokenSoftCap: Int? {
        switch self {
        case .flux2Klein4B, .flux2Klein9B, .flux2KleinBase4B, .flux2KleinBase9B: 512
        case .krea2: 1024 // krea/Krea-2 qwen3vl tokenizer, max_length=1024
        case .zimageTurbo, .zimage: 512 // Qwen3-4B encoder at max_sequence_length=512
        case .flux3Klein, .flux3KleinBase: 4096 // mflux ModelConfig max_sequence_length for FLUX 3
        case .ideogram4, .qwen21Turbo, .custom: nil
        }
    }

    var recommendedQuantize: Int {
        8
    }

    var mfluxModelID: String {
        switch self {
        case .krea2: "krea/Krea-2-Turbo" // official repo; rawValue "krea2" is reserved for local paths/keys
        case .zimageTurbo: "Tongyi-MAI/Z-Image-Turbo"
        case .zimage: "Tongyi-MAI/Z-Image"
        default: rawValue
        }
    }

    /// Root-config key to pass via `--base-model` for pre-saved community repos. FLUX 3 repo
    /// names (`mflux-community/flux-3-image-klein-mflux-q8`) contain no "flux3*" alias substring,
    /// so mflux's config resolver cannot infer them ("Cannot infer base_model"). Nil when the
    /// name is self-describing and inference (or a probed `--base-model`) suffices.
    var baseModelKey: String? {
        switch self {
        case .flux3Klein: "flux3-image-klein"
        case .flux3KleinBase: "flux3-image-klein-base"
        default: nil
        }
    }

    /// Which pipeline — runner, params panel, LoRA scope — this variant runs
    /// through. `custom` has no family of its own; ask its target instead (see
    /// ``ParamsPanelState/modelFamily``).
    var family: ModelFamily {
        switch self {
        case .ideogram4: .ideogram4
        case .krea2: .krea2
        case .zimageTurbo, .zimage: .zimage
        case .qwen21Turbo: .qwen21
        case .flux2Klein4B, .flux2Klein9B, .flux2KleinBase4B, .flux2KleinBase9B,
             .flux3Klein, .flux3KleinBase, .custom: .flux
        }
    }

    /// The tool this variant generates with, or nil when the variant has no
    /// tool of its own (`custom` inherits its target's). The bundled runtime
    /// ships every one; a Custom Python may not (see ``Toolchain/hasTool(_:)``).
    var generateTool: PythonTool? {
        switch self {
        case .flux2Klein4B, .flux2Klein9B, .flux2KleinBase4B, .flux2KleinBase9B: .flux2
        case .ideogram4: .ideogram4
        case .krea2: .krea2
        case .zimageTurbo: .zImageTurbo
        case .zimage: .zImage
        case .flux3Klein, .flux3KleinBase: .flux3
        case .qwen21Turbo: .qwen21Edit
        case .custom: nil
        }
    }

    /// Label for the Q0 (base) weights. Every model loads its mflux-community BF16 repo there.
    var baseWeightLabel: String {
        "BF16"
    }

    /// The key ``hf_cache_probe.py``'s weight-definition table uses for this
    /// variant. Normally the family id — one loader per family decides which
    /// files make a download complete. FLUX 3 is the exception: it rides the
    /// `.flux` pipeline but has its own loader (and Base carries different
    /// weights), so each variant gets a dedicated key.
    var probeKey: String {
        switch self {
        case .flux3Klein: "flux3"
        case .flux3KleinBase: "flux3-base"
        default: family.id
        }
    }

    /// The `<stem>` of this model's `mflux-community/<stem>-mflux-<level>` repos, the stem
    /// mflux's own registry gives it (`mflux_repo_stem`). Nil for `custom`.
    var communityRepoStem: String? {
        switch self {
        case .flux2Klein4B: "flux2-klein-4b"
        case .flux2Klein9B: "flux2-klein-9b"
        case .flux2KleinBase4B: "flux-2-klein-base-4b"
        case .flux2KleinBase9B: "flux-2-klein-base-9b"
        case .flux3Klein: "flux-3-image-klein"
        case .flux3KleinBase: "flux-3-image-klein-base"
        case .ideogram4: "ideogram-4"
        case .krea2: "krea-2-turbo"
        case .zimageTurbo: "z-image-turbo"
        case .zimage: "z-image-base"
        case .qwen21Turbo: "qwen-image-2-1-turbo"
        case .custom: nil
        }
    }

    /// Whether a legacy `saved/` copy (written by the app's old mflux-save pass) is still
    /// loaded in preference to the published repo, so nobody downloads a model twice. Not for
    /// Ideogram 4, whose old copies are stale, nor FLUX 3 and Qwen-Image 2.1, which never had any.
    var usesLegacySavedWeights: Bool {
        !isIdeogram4 && !isFlux3 && !isQwen21 && self != .custom
    }

    /// Whether a job picked as this model sends its negative prompt, when it runs as
    /// `loadsAs` (itself, or a custom checkpoint's target). FLUX 3 rejects
    /// `--negative-prompt` outright, so a custom FLUX 3 drops it.
    func sendsNegativePrompt(loadsAs: Self) -> Bool {
        supportsNegativePrompt && !(self == .custom && loadsAs.isFlux3)
    }

    /// Where the app's old mflux-save pass wrote this model + quantize level:
    /// {MFLUX_CACHE_DIR}/saved/{rawValue}-q{quantize}/. Nothing writes here now; see
    /// ``legacySavedWeights(quantize:in:)``.
    func savedModelPath(quantize: Int, in cacheDir: URL) -> URL {
        cacheDir.appendingPathComponent("saved/\(rawValue)-q\(quantize)", isDirectory: true)
    }

    /// The Hugging Face page of the repo this model loads at `quantize`, for the
    /// failed-job view's link to it.
    func hfRepoURL(quantize: Int) -> URL? {
        publishedRepoID(quantize: quantize).flatMap { URL(string: "https://huggingface.co/\($0)") }
    }

    /// The mflux-community repo this model loads at `quantize` (0 = BF16, 8, 4), passed to mflux
    /// as `--model` with no `--quantize`. These are mflux-save uploads: ungated, only the files
    /// mflux reads, and already quantized, so a Q4 run never downloads or loads the BF16 weights.
    /// mflux 0.24.0 infers each one's config from the name, except FLUX 3 (``baseModelKey``).
    /// Nil for `custom`, or a level the app doesn't offer.
    func publishedRepoID(quantize: Int) -> String? {
        guard let stem = communityRepoStem else { return nil }
        switch quantize {
        case 0: return "mflux-community/\(stem)-mflux-bf16"
        case 4, 8: return "mflux-community/\(stem)-mflux-q\(quantize)"
        default: return nil
        }
    }

    /// Approximate on-disk / unified-memory footprint in GB for a quantize level: the
    /// measured size of the mflux-community repo it loads (HF API, 2026-11-21).
    func approximateSizeGB(quantize: Int) -> Double {
        // BF16, Q8, Q4.
        let sizes: [Double] = switch self {
        case .flux2Klein4B, .flux2KleinBase4B: [16.0, 8.6, 4.6]
        case .flux2Klein9B, .flux2KleinBase9B: [33.5, 17.9, 9.5]
        case .flux3Klein, .flux3KleinBase: [18.5, 9.9, 5.3]
        case .ideogram4: [27.0, 27.9, 14.9] // measured: its q8 repo is slightly larger than its bf16 one
        case .krea2: [34.2, 22.2, 15.8]
        case .zimageTurbo, .zimage: [20.5, 11.0, 5.9]
        case .qwen21Turbo: [32.5, 17.8, 10.0]
        case .custom: [0, 0, 0]
        }
        return sizes[quantize == 4 ? 2 : quantize == 8 ? 1 : 0]
    }

    /// The "≈N GB RAM" label's figure: the measured peak for the path the job will run where it is known
    /// (Qwen-Image 2.1), else the weight size. ``approximateSizeGB(quantize:)`` stays the download size.
    func approximateRAMGB(quantize: Int, settings: AppSettings) -> Double {
        // A ComfyUI-routed job runs on the server, so no local peak applies: keep the weight size, as other models do.
        guard isQwen21, !Qwen21RunnerSpec.routesToComfy(settings: settings) else { return approximateSizeGB(quantize: quantize) }
        // MLX peaks measured 2026-11-15 on mflux 0.24.0: the heavier of a 1024² Generate and a ~1 MP
        // one-reference Edit at 8 steps. Columns: one-shot CLI (it frees the text encoder before denoising),
        // warm driver keeping the encoder, warm driver evicting it.
        let peaks: [Double] = switch quantize {
        case 4: [10.3, 16.5, 11.4]
        case 8: [13.8, 24.4, 18.5]
        default: [24.8, 43.3, 33.2]
        }
        // Low-RAM jobs always run on the CLI, which their block streaming only lowers further.
        guard settings.keepModelWarm, !settings.resolvedDefaults(for: self).lowRam else { return peaks[0] }
        // Automatic keeps the encoder until a job peaks above 70% of RAM, so it shows the keep figure.
        return settings.warmTextEncoderPolicy == .evict ? peaks[2] : peaks[1]
    }

    /// Returns true for a specific quantize level: a legacy mflux-save copy the runner still
    /// loads (``usesLegacySavedWeights``), else the published repo in the hub cache.
    func isOnDisk(quantize: Int, savedIn cacheDir: URL, hubDir: URL) -> Bool {
        legacySavedWeights(quantize: quantize, in: cacheDir) != nil || isOnDisk(quantize: quantize, hubDir: hubDir)
    }

    /// The legacy mflux-save copy the runner loads at `quantize`, or nil when there is none
    /// (or the model ignores them, see ``usesLegacySavedWeights``).
    func legacySavedWeights(quantize: Int, in cacheDir: URL) -> URL? {
        guard usesLegacySavedWeights else { return nil }
        let path = savedModelPath(quantize: quantize, in: cacheDir)
        return Self.hasSavedWeights(at: path) ? path : nil
    }

    /// Returns true for a specific quantize level (0=bf16, 4=q4, 8=q8), only if fully downloaded.
    func isOnDisk(quantize: Int, hubDir: URL) -> Bool {
        guard let url = onDiskURL(quantize: quantize, hubDir: hubDir) else { return false }
        return Self.isCompleteHFCache(at: url)
    }

    /// Returns the HF hub cache directory URL for the given quantize level, only if fully downloaded.
    /// `hubDir` is the models folder's `hub/` (``AppSettings/hfHubDir``): the
    /// person's chosen HF_HOME, never assumed to be under the home folder,
    /// which in the App Store build is the app's container.
    func onDiskURL(quantize: Int, hubDir: URL) -> URL? {
        guard let url = hubCacheFolder(quantize: quantize, hubDir: hubDir) else { return nil }
        return Self.isCompleteHFCache(at: url) ? url : nil
    }

    /// The HF hub cache directory the given quantize level downloads into, when
    /// it exists, complete or not: the published repo's `models--org--name`.
    func hubCacheFolder(quantize: Int, hubDir: URL) -> URL? {
        guard let repo = publishedRepoID(quantize: quantize) else { return nil }
        let folder = ModelDownloadStore.cacheFolder(repo: repo, hubDir: hubDir)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }
}

extension FluxModelVariant {
    /// A text field commits on focus loss without `.onSubmit`, so every job and saved default clamps here.
    func clampedSteps(_ steps: Int) -> Int {
        min(max(steps, 1), maxSteps)
    }
}
