import Foundation

// MARK: - Ideogram 4 metadata

nonisolated struct Ideogram4Metadata: Codable {
    @MainActor static func from(job: Ideogram4Job) -> Self {
        Self(
            caption: job.caption,
            usePlainPrompt: job.usePlainPrompt,
            plainPrompt: job.plainPrompt,
            preset: job.preset,
            seed: job.resolvedSeed ?? job.seed,
            width: job.width,
            height: job.height,
            quantize: job.quantize,
            lowRam: job.lowRam,
            loras: job.loras.isEmpty ? nil : job.loras,
            board: job.board.isEmpty ? nil : job.board,
            generatedAt: job.completedAt ?? Date(),
            startedAt: job.startedAt,
            log: job.log.isEmpty ? nil : job.log
        )
    }

    var caption: IdeogramCaption
    var usePlainPrompt: Bool
    var plainPrompt: String
    var preset: Ideogram4Preset
    var seed: Int
    var width: Int
    var height: Int
    var quantize: Int
    var lowRam: Bool
    // Optional so existing sidecars (written before LoRA support) still decode.
    var loras: [LoraEntry]?
    var board: String?
    var generatedAt: Date
    var startedAt: Date?
    var log: String?
}

// MARK: - FLUX metadata

nonisolated struct GenerationMetadata: Codable {
    @MainActor static func from(job: FluxJob) -> Self {
        Self(
            prompt: job.prompt,
            negativePrompt: job.negativePrompt,
            model: job.model,
            customModelRepo: job.customModelRepo,
            customBaseModel: job.customBaseModel,
            seed: job.resolvedSeed ?? job.seed,
            steps: job.steps,
            guidance: job.guidance,
            width: job.width,
            height: job.height,
            quantize: job.quantize,
            lowRam: job.lowRam,
            imagePath: job.imagePath,
            imageStrength: job.imageStrength,
            loras: job.loras,
            board: job.board.isEmpty ? nil : job.board,
            generatedAt: job.completedAt ?? Date(),
            startedAt: job.startedAt,
            log: job.log.isEmpty ? nil : job.log
        )
    }

    var prompt: String
    var negativePrompt: String
    var model: FluxModelVariant
    var customModelRepo: String
    var customBaseModel: FluxModelVariant
    var seed: Int
    var steps: Int
    var guidance: Double
    var width: Int
    var height: Int
    var quantize: Int
    var lowRam: Bool
    var imagePath: String
    var imageStrength: Double
    var loras: [LoraEntry]
    var board: String?
    var generatedAt: Date
    var startedAt: Date?
    var log: String?
}

// MARK: - Krea 2 metadata

nonisolated struct Krea2Metadata: Codable {
    @MainActor static func from(job: Krea2Job) -> Self {
        Self(
            prompt: job.prompt,
            negativePrompt: job.negativePrompt.isEmpty ? nil : job.negativePrompt,
            seed: job.resolvedSeed ?? job.seed,
            steps: job.steps,
            guidance: job.guidance,
            width: job.width,
            height: job.height,
            quantize: job.quantize,
            loras: job.loras.isEmpty ? nil : job.loras,
            imagePath: job.imagePath.isEmpty ? nil : job.imagePath,
            imageStrength: job.imagePath.isEmpty ? nil : job.imageStrength,
            board: job.board.isEmpty ? nil : job.board,
            generatedAt: job.completedAt ?? Date(),
            startedAt: job.startedAt,
            log: job.log.isEmpty ? nil : job.log
        )
    }

    var prompt: String
    var negativePrompt: String?
    var seed: Int
    var steps: Int
    var guidance: Double
    var width: Int
    var height: Int
    var quantize: Int
    var loras: [LoraEntry]?
    var imagePath: String?
    var imageStrength: Double?
    var board: String?
    var generatedAt: Date
    var startedAt: Date?
    var log: String?
}

// MARK: - Z-Image metadata

nonisolated struct ZImageMetadata: Codable {
    @MainActor static func from(job: ZImageJob) -> Self {
        Self(
            modelVariant: job.modelVariant,
            prompt: job.prompt,
            negativePrompt: job.negativePrompt.isEmpty ? nil : job.negativePrompt,
            seed: job.resolvedSeed ?? job.seed,
            steps: job.steps,
            guidance: job.guidance,
            width: job.width,
            height: job.height,
            quantize: job.quantize,
            loras: job.loras.isEmpty ? nil : job.loras,
            imagePath: job.imagePath.isEmpty ? nil : job.imagePath,
            imageStrength: job.imagePath.isEmpty ? nil : job.imageStrength,
            board: job.board.isEmpty ? nil : job.board,
            generatedAt: job.completedAt ?? Date(),
            startedAt: job.startedAt,
            log: job.log.isEmpty ? nil : job.log
        )
    }

    /// Which Z-Image variant produced the image (Turbo or base). Optional so
    /// sidecars written before the field decode; defaults to Turbo on read.
    var modelVariant: FluxModelVariant?
    var prompt: String
    var negativePrompt: String?
    var seed: Int
    var steps: Int
    var guidance: Double
    var width: Int
    var height: Int
    var quantize: Int
    var loras: [LoraEntry]?
    var imagePath: String?
    var imageStrength: Double?
    var board: String?
    var generatedAt: Date
    var startedAt: Date?
    var log: String?

    /// Resolved variant, defaulting to Turbo for pre-field sidecars.
    var resolvedVariant: FluxModelVariant {
        modelVariant ?? .zimageTurbo
    }
}

// MARK: - SeedVR2 metadata

/// The pre-upscale generation metadata resolved from a source image's sidecar.
/// Exactly one family is non-nil (or all nil when the source carried no sidecar).
nonisolated struct SeedVR2Source {
    var flux: GenerationMetadata?
    var ideogram4: Ideogram4Metadata?
    var krea2: Krea2Metadata?
    var zimage: ZImageMetadata?
}

/// Source-forward display fields for a SeedVR2 upscale, derived from the source
/// generation metadata folded into its sidecar. Failable: nil when the source
/// carried no sidecar, so callers fall back to showing the upscale parameters.
nonisolated struct SeedVR2DisplayFields {
    var prompt: String
    var negativePrompt: String
    var sourceModel: String
    var steps: Int
    var guidance: Double
    var loras: [LoraEntry]
    var seed: Int
    var width: Int
    var height: Int

    init?(source: SeedVR2Source) {
        if let s = source.flux {
            prompt = s.prompt
            negativePrompt = s.negativePrompt
            sourceModel = s.model == .custom ? "Custom" : s.model.displayName
            steps = s.steps
            guidance = s.guidance
            loras = s.loras
            seed = s.seed
            width = s.width
            height = s.height
        } else if let s = source.ideogram4 {
            prompt = s.usePlainPrompt ? s.plainPrompt : s.caption.highLevelDescription
            negativePrompt = ""
            sourceModel = "Ideogram 4"
            steps = s.preset.stepCount
            guidance = 1.0
            loras = s.loras ?? []
            seed = s.seed
            width = s.width
            height = s.height
        } else if let s = source.krea2 {
            prompt = s.prompt
            negativePrompt = s.negativePrompt ?? ""
            sourceModel = "Krea 2 Turbo"
            steps = s.steps
            guidance = s.guidance
            loras = s.loras ?? []
            seed = s.seed
            width = s.width
            height = s.height
        } else if let s = source.zimage {
            prompt = s.prompt
            negativePrompt = s.negativePrompt ?? ""
            sourceModel = s.resolvedVariant.displayName
            steps = s.steps
            guidance = s.guidance
            loras = s.loras ?? []
            seed = s.seed
            width = s.width
            height = s.height
        } else {
            return nil
        }
    }
}

nonisolated struct SeedVR2Metadata: Codable {
    @MainActor static func from(job: SeedVR2Job) -> Self {
        let source = resolveSource(for: job.sourcePath)
        return Self(
            sourcePath: job.sourcePath,
            model: job.is7B ? "seedvr2-7b" : "seedvr2-3b",
            scale: job.scale,
            softness: job.softness,
            quantize: job.quantize,
            seed: job.resolvedSeed ?? job.seed,
            width: job.width,
            height: job.height,
            board: job.board.isEmpty ? nil : job.board,
            generatedAt: job.completedAt ?? Date(),
            startedAt: job.startedAt,
            log: job.log.isEmpty ? nil : job.log,
            sourceFlux: source.flux,
            sourceIdeogram4: source.ideogram4,
            sourceKrea2: source.krea2,
            sourceZImage: source.zimage
        )
    }

    /// Reads the source image's sidecar so the upscale can stand on its own once the
    /// original is deleted. At most one family is non-nil (the reads are mutually
    /// exclusive — a sidecar decodes as exactly one family). If the source is itself
    /// an upscale, its already-inherited source is carried forward so chained
    /// upscales don't lose the original recipe (no recursion — one hop, flattened).
    nonisolated static func resolveSource(for sourcePath: String) -> SeedVR2Source {
        // Z-Image and Krea 2 sidecars share an identical required-field shape, so a
        // blind decode is ambiguous (a Z-Image sidecar decodes cleanly as Krea 2).
        // Disambiguate by the source filename prefix first — mirroring
        // GalleryStore's classifier — before the generic decode chain below.
        let name = (sourcePath as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("zimage"), let zimage = MetadataSidecar.readZImage(for: sourcePath) {
            return SeedVR2Source(zimage: zimage)
        }
        if name.hasPrefix("krea2"), let krea2 = MetadataSidecar.readKrea2(for: sourcePath) {
            return SeedVR2Source(krea2: krea2)
        }
        if let flux = MetadataSidecar.read(for: sourcePath) {
            return SeedVR2Source(flux: flux)
        }
        if let ideogram4 = MetadataSidecar.readIdeogram4(for: sourcePath) {
            return SeedVR2Source(ideogram4: ideogram4)
        }
        if let krea2 = MetadataSidecar.readKrea2(for: sourcePath) {
            return SeedVR2Source(krea2: krea2)
        }
        if let zimage = MetadataSidecar.readZImage(for: sourcePath) {
            return SeedVR2Source(zimage: zimage)
        }
        if let priorUpscale = MetadataSidecar.readSeedVR2(for: sourcePath) {
            return SeedVR2Source(
                flux: priorUpscale.sourceFlux,
                ideogram4: priorUpscale.sourceIdeogram4,
                krea2: priorUpscale.sourceKrea2,
                zimage: priorUpscale.sourceZImage
            )
        }
        return SeedVR2Source()
    }

    var sourcePath: String
    var model: String
    var scale: Int
    var softness: Double
    var quantize: Int
    var seed: Int
    var width: Int
    var height: Int
    var board: String?
    var generatedAt: Date
    var startedAt: Date?
    var log: String?

    // Source (pre-upscale) generation metadata, captured at write time. Exactly one
    // is non-nil (or all nil for a source that carried no sidecar). Lets the upscale
    // display the original prompt/loras and replay via Apply-Settings/Remix.
    var sourceFlux: GenerationMetadata?
    var sourceIdeogram4: Ideogram4Metadata?
    var sourceKrea2: Krea2Metadata?
    var sourceZImage: ZImageMetadata?
}

enum MetadataSidecar {
    static func write(_ metadata: GenerationMetadata, for imagePath: String) {
        let url = sidecarURL(for: imagePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func writeIdeogram4(_ metadata: Ideogram4Metadata, for imagePath: String) {
        let url = sidecarURL(for: imagePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func writeKrea2(_ metadata: Krea2Metadata, for imagePath: String) {
        let url = sidecarURL(for: imagePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func writeZImage(_ metadata: ZImageMetadata, for imagePath: String) {
        let url = sidecarURL(for: imagePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func writeSeedVR2(_ metadata: SeedVR2Metadata, for imagePath: String) {
        let url = sidecarURL(for: imagePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func read(for imagePath: String) -> GenerationMetadata? {
        let url = sidecarURL(for: imagePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GenerationMetadata.self, from: data)
    }

    nonisolated static func readIdeogram4(for imagePath: String) -> Ideogram4Metadata? {
        let url = sidecarURL(for: imagePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Ideogram4Metadata.self, from: data)
    }

    nonisolated static func readKrea2(for imagePath: String) -> Krea2Metadata? {
        let url = sidecarURL(for: imagePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Krea2Metadata.self, from: data)
    }

    nonisolated static func readZImage(for imagePath: String) -> ZImageMetadata? {
        let url = sidecarURL(for: imagePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ZImageMetadata.self, from: data)
    }

    nonisolated static func readSeedVR2(for imagePath: String) -> SeedVR2Metadata? {
        let url = sidecarURL(for: imagePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SeedVR2Metadata.self, from: data)
    }

    nonisolated static func sidecarURL(for imagePath: String) -> URL {
        URL(fileURLWithPath: imagePath).deletingPathExtension().appendingPathExtension("json")
    }
}
