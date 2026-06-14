import Foundation

enum FluxModelVariant: String, CaseIterable, Codable, Hashable {
    case flux2Klein4B = "flux2-klein-4b"
    case flux2Klein9B = "flux2-klein-9b"
    case flux2KleinBase4B = "flux2-klein-base-4b"
    case flux2KleinBase9B = "flux2-klein-base-9b"
    case custom

    static var builtIn: [Self] {
        [.flux2Klein9B, .flux2Klein4B, .flux2KleinBase9B, .flux2KleinBase4B]
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

    var displayName: String {
        switch self {
        case .flux2Klein4B: "FLUX.2 Klein 4B"
        case .flux2Klein9B: "FLUX.2 Klein 9B"
        case .flux2KleinBase4B: "FLUX.2 Klein Base 4B"
        case .flux2KleinBase9B: "FLUX.2 Klein Base 9B"
        case .custom: "Custom Model"
        }
    }

    var isDistilled: Bool {
        self == .flux2Klein4B || self == .flux2Klein9B
    }

    var defaultSteps: Int {
        isDistilled ? 4 : 50
    }

    var defaultGuidance: Double {
        isDistilled ? 1.0 : 3.5
    }

    var supportsNegativePrompt: Bool {
        self == .custom
    }

    var approximateBF16SizeGB: Double {
        switch self {
        case .flux2Klein4B, .flux2KleinBase4B: 15.0
        case .flux2Klein9B, .flux2KleinBase9B: 35.0
        case .custom: 0
        }
    }

    var recommendedQuantize: Int {
        switch self {
        case .flux2Klein4B, .flux2KleinBase4B: 8
        case .flux2Klein9B, .flux2KleinBase9B: 8
        case .custom: 8
        }
    }

    var mfluxModelID: String {
        rawValue
    }

    /// BF16 source repo on HuggingFace (used when no pre-quantized repo exists).
    var bf16HFRepoID: String? {
        switch self {
        case .flux2Klein9B: "mlx-community/flux2-klein-9b-bf16"
        case .flux2Klein4B: "mlx-community/flux2-klein-4b-bf16"
        case .flux2KleinBase9B: "black-forest-labs/FLUX.2-klein-base-9B"
        case .flux2KleinBase4B: "black-forest-labs/FLUX.2-klein-base-4B"
        case .custom: nil
        }
    }

    /// The BF16 HF repo uses "FLUX.2-klein-…" (with a dot) while rawValue uses "flux2-klein-…".
    /// This key is used to match the BF16 cache directory by its actual name pattern.
    var bf16CacheKey: String {
        switch self {
        case .flux2Klein9B: "flux.2-klein-9b"
        case .flux2Klein4B: "flux.2-klein-4b"
        case .flux2KleinBase9B: "flux.2-klein-base-9b"
        case .flux2KleinBase4B: "flux.2-klein-base-4b"
        case .custom: ""
        }
    }

    /// Returns true if any quantized variant of this model is found in the HuggingFace hub cache.
    var isOnDisk: Bool {
        guard self != .custom else { return false }
        let hubDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hubDir.path) else { return false }
        let key = rawValue.lowercased()
        return entries.contains { $0.lowercased().contains(key) }
            || (!bf16CacheKey.isEmpty && entries.contains { $0.lowercased().contains(bf16CacheKey) })
    }

    /// Local path where mflux-save writes quantized weights for this model + quantize level.
    /// Stored under {MFLUX_CACHE_DIR}/saved/{rawValue}-q{quantize}/.
    func savedModelPath(quantize: Int, in cacheDir: URL) -> URL {
        cacheDir.appendingPathComponent("saved/\(rawValue)-q\(quantize)", isDirectory: true)
    }

    /// Returns the HuggingFace repo URL for this model + quantize combination, if known.
    /// Used to link users directly to the gated repo so they can accept terms.
    func hfRepoURL(quantize: Int) -> URL? {
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
        default: nil
        }
    }

    /// Returns true for a specific quantize level, checking the mflux saved-weights dir first,
    /// then falling back to the HuggingFace hub cache.
    func isOnDisk(quantize: Int, savedIn cacheDir: URL) -> Bool {
        let savePath = savedModelPath(quantize: quantize, in: cacheDir)
        if Self.hasSavedWeights(at: savePath) { return true }
        return isOnDisk(quantize: quantize)
    }

    /// Returns true for a specific quantize level (0=bf16, 4=q4, 8=q8).
    func isOnDisk(quantize: Int) -> Bool {
        guard self != .custom else { return false }
        let hubDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hubDir.path) else { return false }
        switch quantize {
        case 8:
            let key = rawValue.lowercased()
            return entries.contains { $0.lowercased().contains(key) && $0.contains("8bit") }

        case 4:
            let key = rawValue.lowercased()
            return entries.contains { $0.lowercased().contains(key) && $0.contains("4bit") }

        default: // BF16: original org repo uses "FLUX.2-…" with a dot
            guard !bf16CacheKey.isEmpty else { return false }
            return entries.contains { $0.lowercased().contains(bf16CacheKey) }
        }
    }

    /// Returns the HF hub cache directory URL for the given quantize level, if present.
    func onDiskURL(quantize: Int) -> URL? {
        guard self != .custom else { return nil }
        let hubDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hubDir.path) else { return nil }
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
