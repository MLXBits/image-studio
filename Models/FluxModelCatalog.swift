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
    case custom

    /// Flux.2 variants only — used for base-model pickers and LoRA sections.
    static var builtIn: [Self] {
        [.flux2Klein9B, .flux2Klein4B, .flux2KleinBase9B, .flux2KleinBase4B]
    }

    /// All non-custom models shown in Settings → Models. FLUX 3 first: it is the
    /// newest model and the one users will be looking for.
    static var allModels: [Self] {
        [.flux3Klein, .flux3KleinBase] + builtIn + [.ideogram4, .krea2, .zimageTurbo, .zimage]
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

    /// Returns true if mflux-saved weights already exist at the given path.
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

    var isFlux: Bool {
        !isIdeogram4 && !isKrea2 && !isZImage && self != .custom
    }

    var displayName: String {
        switch self {
        case .flux2Klein4B: "FLUX.2 Klein 4B"
        case .flux2Klein9B: "FLUX.2 Klein 9B"
        case .flux2KleinBase4B: "FLUX.2 Klein Base 4B"
        case .flux2KleinBase9B: "FLUX.2 Klein Base 9B"
        case .ideogram4: "Ideogram 4"
        case .krea2: "Krea 2 Turbo"
        case .zimageTurbo: "Z-Image Turbo"
        case .zimage: "Z-Image"
        case .flux3Klein: "FLUX.3 Klein"
        case .flux3KleinBase: "FLUX.3 Klein Base"
        case .custom: "Custom Model"
        }
    }

    var isDistilled: Bool {
        self == .flux2Klein4B || self == .flux2Klein9B || self == .zimageTurbo || self == .flux3Klein
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
        case .flux3Klein: 16 // distilled Klein is designed for ~16 steps (mflux default)
        default: isDistilled ? 4 : 50 // flux3KleinBase lands here at 50, its CFG default
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
        case .ideogram4, .custom: nil
        }
    }

    var approximateBF16SizeGB: Double {
        switch self {
        case .flux2Klein4B, .flux2KleinBase4B: 15.0
        case .flux2Klein9B, .flux2KleinBase9B: 35.0
        case .ideogram4: 28.0 // FP8 checkpoint
        case .krea2: 27.0 // krea/Krea-2-Turbo (~26.6 GB bf16)
        case .zimageTurbo, .zimage: 20.0 // 6.15B DiT + Qwen3-4B encoder + VAE, bf16
        case .flux3Klein, .flux3KleinBase: 18.5 // mflux-community BF16 repo (text encoder + transformer + VAE)
        case .custom: 0
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
        case .custom: nil
        }
    }

    /// Label for the Q0 (base) weights. BF16 for Flux, FP8 for Ideogram 4.
    var baseWeightLabel: String {
        self == .ideogram4 ? "FP8" : "BF16"
    }

    /// BF16/FP8 source repo on HuggingFace (used when no pre-quantized repo exists).
    /// FLUX 3 points at the ungated mflux-community MLX layout instead of the gated BFL
    /// source — same weights, re-sharded for direct load, ~4× smaller than the raw repo.
    var bf16HFRepoID: String? {
        switch self {
        case .flux2Klein9B: "mlx-community/flux2-klein-9b-bf16"
        case .flux2Klein4B: "mlx-community/flux2-klein-4b-bf16"
        case .flux2KleinBase9B: "black-forest-labs/FLUX.2-klein-base-9B"
        case .flux2KleinBase4B: "black-forest-labs/FLUX.2-klein-base-4B"
        case .ideogram4: nil // gated — user must accept terms manually
        case .krea2: "krea/Krea-2-Turbo"
        case .zimageTurbo: "Tongyi-MAI/Z-Image-Turbo"
        case .zimage: "Tongyi-MAI/Z-Image"
        case .flux3Klein: "mflux-community/flux-3-image-klein-mflux-bf16"
        case .flux3KleinBase: "mflux-community/flux-3-image-klein-base-mflux-bf16"
        case .custom: nil
        }
    }

    /// Pattern used to match the model's base-weight directory in the HF hub cache.
    var bf16CacheKey: String {
        switch self {
        case .flux2Klein9B: "flux.2-klein-9b"
        case .flux2Klein4B: "flux.2-klein-4b"
        case .flux2KleinBase9B: "flux.2-klein-base-9b"
        case .flux2KleinBase4B: "flux.2-klein-base-4b"
        case .ideogram4: "ideogram-4-fp8"
        case .krea2: "krea-2-turbo"
        case .zimageTurbo: "z-image-turbo"
        case .zimage: "tongyi-mai--z-image"
        case .flux3Klein: "flux-3-image-klein"
        case .flux3KleinBase: "flux-3-image-klein-base"
        case .custom: ""
        }
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

    /// Local path where mflux-save writes quantized weights for this model + quantize level.
    /// Stored under {MFLUX_CACHE_DIR}/saved/{rawValue}-q{quantize}/.
    func savedModelPath(quantize: Int, in cacheDir: URL) -> URL {
        cacheDir.appendingPathComponent("saved/\(rawValue)-q\(quantize)", isDirectory: true)
    }

    /// Returns the HuggingFace repo URL for this model + quantize combination, if known.
    /// Used to link users directly to the gated repo so they can accept terms.
    /// Ideogram 4 has no `bf16HFRepoID`, so its FP8 page is the fallback.
    func hfRepoURL(quantize: Int) -> URL? {
        let fallback = self == .ideogram4 ? "ideogram-ai/ideogram-4-fp8" : bf16HFRepoID
        let repoID = preQuantizedRepoID(quantize: quantize) ?? fallback
        return repoID.flatMap { URL(string: "https://huggingface.co/\($0)") }
    }

    /// Returns the HF repo ID of a pre-saved model published by mlx-community / mflux-community,
    /// if one is known. When present, mflux is passed this repo directly (no --quantize flag) so it
    /// loads pre-quantized weights without needing the full BF16 model in memory. FLUX 3 has a
    /// published repo at every precision — including BF16 — because its BFL source repos are gated;
    /// those are ungated mirrors of the same weights, re-sharded in mflux layout with a manifest.
    func preQuantizedRepoID(quantize: Int) -> String? {
        switch (self, quantize) {
        case (.flux2Klein9B, 8): "mlx-community/flux2-klein-9b-8bit"
        case (.flux2Klein4B, 8): "mlx-community/flux2-klein-4b-8bit"
        case (.ideogram4, 8): "mflux-community/ideogram-4-mflux-q8"
        case (.ideogram4, 4): "mflux-community/ideogram-4-mflux-q4"
        case (.zimageTurbo, 4): "filipstrand/Z-Image-Turbo-mflux-4bit"
        case (.flux3Klein, 0): "mflux-community/flux-3-image-klein-mflux-bf16"
        case (.flux3Klein, 8): "mflux-community/flux-3-image-klein-mflux-q8"
        case (.flux3Klein, 4): "mflux-community/flux-3-image-klein-mflux-q4"
        case (.flux3KleinBase, 0): "mflux-community/flux-3-image-klein-base-mflux-bf16"
        case (.flux3KleinBase, 8): "mflux-community/flux-3-image-klein-base-mflux-q8"
        case (.flux3KleinBase, 4): "mflux-community/flux-3-image-klein-base-mflux-q4"
        default: nil
        }
    }

    /// Approximate on-disk / unified-memory footprint in GB for a quantize level.
    /// Ideogram 4 ships as FP8 (already 8-bit), so its Q8 is roughly FP8-sized while
    /// Q4 roughly halves it — the generic BF16×factor model doesn't apply.
    func approximateSizeGB(quantize: Int) -> Double {
        if self == .ideogram4 {
            switch quantize {
            case 4: return 14
            case 8: return 26
            default: return 28
            }
        }
        // Krea 2 quantizes only the transformer; the Qwen3-VL text encoder + VAE stay
        // BF16, so the saved dir is larger than the generic BF16×factor estimate.
        if self == .krea2 {
            switch quantize {
            case 4: return 12
            case 8: return 21
            default: return 27
            }
        }
        // Z-Image quantizes the transformer; the Qwen3-4B encoder + VAE stay BF16,
        // so the footprint sits above the generic BF16×factor estimate.
        if isZImage {
            switch quantize {
            case 4: return 10
            case 8: return 14
            default: return 20
            }
        }
        // FLUX 3 downloads a pre-saved mflux-community repo per precision, so use the
        // measured sizes of those repos rather than scaling BF16 by a generic factor.
        if isFlux3 {
            switch quantize {
            case 4: return 5.3
            case 8: return 9.9
            default: return 18.5
            }
        }
        let factor: Double = quantize == 4 ? 0.25 : quantize == 8 ? 0.5 : 1.0
        return approximateBF16SizeGB * factor
    }

    /// Returns true for a specific quantize level, checking the mflux saved-weights dir first,
    /// then falling back to the HuggingFace hub cache.
    func isOnDisk(quantize: Int, savedIn cacheDir: URL, hubDir: URL) -> Bool {
        // Ideogram Q8/Q4 load pre-quantized weights straight from the HF cache; the
        // legacy mflux-save dir is never used for them and may be stale, so ignore it
        // and report on-disk purely from the published repo's cache.
        if isIdeogram4, quantize > 0, preQuantizedRepoID(quantize: quantize) != nil {
            return isOnDisk(quantize: quantize, hubDir: hubDir)
        }
        let savePath = savedModelPath(quantize: quantize, in: cacheDir)
        if Self.hasSavedWeights(at: savePath) {
            return true
        }
        return isOnDisk(quantize: quantize, hubDir: hubDir)
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
    /// it exists, complete or not.
    func hubCacheFolder(quantize: Int, hubDir: URL) -> URL? {
        guard self != .custom else { return nil }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hubDir.path) else { return nil }
        // A published pre-saved repo maps directly to its hub cache dir (models--org--name),
        // so match it explicitly rather than by substring. FLUX 3 uses one at every precision,
        // and the exact name also keeps Klein from claiming Base's nested folder.
        if let repo = preQuantizedRepoID(quantize: quantize) {
            let cacheName = "models--" + repo.replacingOccurrences(of: "/", with: "--")
            return entries.contains(cacheName) ? hubDir.appendingPathComponent(cacheName) : nil
        }
        let match: String?
        switch quantize {
        case 8:
            let key = rawValue.lowercased()
            match = entries.first { $0.lowercased().contains(key) && $0.contains("8bit") }
        case 4:
            let key = rawValue.lowercased()
            match = entries.first { $0.lowercased().contains(key) && $0.contains("4bit") }
        default:
            guard !bf16CacheKey.isEmpty else { return nil }
            match = entries.first { $0.lowercased().contains(bf16CacheKey) }
        }
        return match.map { hubDir.appendingPathComponent($0) }
    }
}
