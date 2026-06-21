import Foundation

enum FluxModelVariant: String, CaseIterable, Codable, Hashable {
    case flux2Klein4B = "flux2-klein-4b"
    case flux2Klein9B = "flux2-klein-9b"
    case flux2KleinBase4B = "flux2-klein-base-4b"
    case flux2KleinBase9B = "flux2-klein-base-9b"
    case ideogram4
    case custom

    /// Flux.2 variants only — used for base-model pickers and LoRA sections.
    static var builtIn: [Self] {
        [.flux2Klein9B, .flux2Klein4B, .flux2KleinBase9B, .flux2KleinBase4B]
    }

    /// All non-custom models shown in Settings → Models.
    static var allModels: [Self] {
        builtIn + [.ideogram4]
    }

    /// Returns true if the HF hub model directory is fully downloaded (no .incomplete blobs).
    static func isCompleteHFCache(at dirURL: URL) -> Bool {
        let blobsURL = dirURL.appendingPathComponent("blobs")
        guard let blobs = try? FileManager.default.contentsOfDirectory(atPath: blobsURL.path),
              !blobs.isEmpty else { return false }
        return !blobs.contains { $0.hasSuffix(".incomplete") }
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
            if ext == "safetensors" { return true }
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

    var isFlux: Bool {
        !isIdeogram4 && self != .custom
    }

    var displayName: String {
        switch self {
        case .flux2Klein4B: "FLUX.2 Klein 4B"
        case .flux2Klein9B: "FLUX.2 Klein 9B"
        case .flux2KleinBase4B: "FLUX.2 Klein Base 4B"
        case .flux2KleinBase9B: "FLUX.2 Klein Base 9B"
        case .ideogram4: "Ideogram 4"
        case .custom: "Custom Model"
        }
    }

    var isDistilled: Bool {
        self == .flux2Klein4B || self == .flux2Klein9B
    }

    var defaultSteps: Int {
        switch self {
        case .ideogram4: 20 // Normal preset (not directly used — preset drives step count)
        default: isDistilled ? 4 : 50
        }
    }

    var defaultGuidance: Double {
        switch self {
        case .ideogram4: 7.0 // not used by Ideogram4 runner
        default: isDistilled ? 1.0 : 3.5
        }
    }

    var supportsNegativePrompt: Bool {
        self == .custom
    }

    var approximateBF16SizeGB: Double {
        switch self {
        case .flux2Klein4B, .flux2KleinBase4B: 15.0
        case .flux2Klein9B, .flux2KleinBase9B: 35.0
        case .ideogram4: 28.0 // FP8 checkpoint
        case .custom: 0
        }
    }

    var recommendedQuantize: Int {
        8
    }

    var mfluxModelID: String {
        rawValue
    }

    /// Label for the Q0 (base) weights. BF16 for Flux, FP8 for Ideogram 4.
    var baseWeightLabel: String {
        self == .ideogram4 ? "FP8" : "BF16"
    }

    /// BF16/FP8 source repo on HuggingFace (used when no pre-quantized repo exists).
    var bf16HFRepoID: String? {
        switch self {
        case .flux2Klein9B: "mlx-community/flux2-klein-9b-bf16"
        case .flux2Klein4B: "mlx-community/flux2-klein-4b-bf16"
        case .flux2KleinBase9B: "black-forest-labs/FLUX.2-klein-base-9B"
        case .flux2KleinBase4B: "black-forest-labs/FLUX.2-klein-base-4B"
        case .ideogram4: nil // gated — user must accept terms manually
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
        case .custom: ""
        }
    }

    /// Returns true if any quantized variant of this model is fully downloaded in the HuggingFace hub cache.
    var isOnDisk: Bool {
        guard self != .custom else { return false }
        let hubDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hubDir.path) else { return false }
        let key = rawValue.lowercased()
        let match = entries.first { $0.lowercased().contains(key) }
            ?? (!bf16CacheKey.isEmpty ? entries.first { $0.lowercased().contains(bf16CacheKey) } : nil)
        guard let match else { return false }
        return Self.isCompleteHFCache(at: hubDir.appendingPathComponent(match))
    }

    /// Local path where mflux-save writes quantized weights for this model + quantize level.
    /// Stored under {MFLUX_CACHE_DIR}/saved/{rawValue}-q{quantize}/.
    func savedModelPath(quantize: Int, in cacheDir: URL) -> URL {
        cacheDir.appendingPathComponent("saved/\(rawValue)-q\(quantize)", isDirectory: true)
    }

    /// Returns the HuggingFace repo URL for this model + quantize combination, if known.
    /// Used to link users directly to the gated repo so they can accept terms.
    func hfRepoURL(quantize: Int) -> URL? {
        if self == .ideogram4 { return URL(string: "https://huggingface.co/ideogram-ai/ideogram-4-fp8") }
        let repoID = preQuantizedRepoID(quantize: quantize) ?? bf16HFRepoID
        return repoID.flatMap { URL(string: "https://huggingface.co/\($0)") }
    }

    /// Returns the HF repo ID of a pre-quantized model published by mlx-community, if one is known.
    /// When present, mflux is passed this repo directly (no --quantize flag) so it loads pre-quantized
    /// weights without needing the full BF16 model in memory.
    func preQuantizedRepoID(quantize: Int) -> String? {
        switch (self, quantize) {
        case (.flux2Klein9B, 8): "mlx-community/flux2-klein-9b-8bit"
        case (.flux2Klein4B, 8): "mlx-community/flux2-klein-4b-8bit"
        case (.ideogram4, 8): "MLXBits/ideogram-4-mlx-q8"
        case (.ideogram4, 4): "MLXBits/ideogram-4-mlx-q4"
        default: nil
        }
    }

    /// Approximate on-disk / unified-memory footprint in GB for a quantize level.
    /// Ideogram 4 ships as FP8 (already 8-bit), so its Q8 is roughly FP8-sized while
    /// Q4 roughly halves it — the generic BF16×factor model doesn't apply.
    func approximateSizeGB(quantize: Int) -> Double {
        if self == .ideogram4 {
            switch quantize {
            case 4: return 15
            case 8: return 27
            default: return 28
            }
        }
        let factor: Double = quantize == 4 ? 0.25 : quantize == 8 ? 0.5 : 1.0
        return approximateBF16SizeGB * factor
    }

    /// Returns true for a specific quantize level, checking the mflux saved-weights dir first,
    /// then falling back to the HuggingFace hub cache.
    func isOnDisk(quantize: Int, savedIn cacheDir: URL) -> Bool {
        let savePath = savedModelPath(quantize: quantize, in: cacheDir)
        if Self.hasSavedWeights(at: savePath) { return true }
        return isOnDisk(quantize: quantize)
    }

    /// Returns true for a specific quantize level (0=bf16, 4=q4, 8=q8), only if fully downloaded.
    func isOnDisk(quantize: Int) -> Bool {
        guard let url = onDiskURL(quantize: quantize) else { return false }
        return Self.isCompleteHFCache(at: url)
    }

    /// Returns the HF hub cache directory URL for the given quantize level, only if fully downloaded.
    func onDiskURL(quantize: Int) -> URL? {
        guard self != .custom else { return nil }
        let hubDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hubDir.path) else { return nil }
        // A published pre-quantized repo maps directly to its hub cache dir
        // (models--org--name), so match it explicitly rather than by substring.
        if quantize > 0, let repo = preQuantizedRepoID(quantize: quantize) {
            let cacheName = "models--" + repo.replacingOccurrences(of: "/", with: "--")
            guard entries.contains(cacheName) else { return nil }
            let url = hubDir.appendingPathComponent(cacheName)
            return Self.isCompleteHFCache(at: url) ? url : nil
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
        guard let match else { return nil }
        let url = hubDir.appendingPathComponent(match)
        return Self.isCompleteHFCache(at: url) ? url : nil
    }
}
