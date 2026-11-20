import Foundation

// MARK: - Ideogram 4 metadata

nonisolated struct Ideogram4Metadata: Codable {
    @MainActor static func from(job: Ideogram4Job) -> Self {
        Self(
            customModelRepo: job.customModelRepo.isEmpty ? nil : job.customModelRepo,
            caption: job.caption,
            usePlainPrompt: job.usePlainPrompt,
            plainPrompt: job.plainPrompt,
            preset: job.preset,
            seed: job.resolvedSeed ?? job.seed,
            width: job.width,
            height: job.height,
            quantize: job.quantize,
            lowRam: job.lowRam,
            loras: job.loras,
            board: job.board.isEmpty ? nil : job.board,
            pidDecode: job.pidDecode ? true : nil,
            pidDegradeSigma: job.pidDegradeSigma > 0 ? job.pidDegradeSigma : nil,
            generatedAt: job.completedAt ?? Date(),
            startedAt: job.startedAt,
            log: job.log.isEmpty ? nil : job.log
        )
    }

    /// Custom checkpoint this was generated from, when the picker's `Custom…`
    /// entry was loaded as Ideogram 4. Optional so pre-field sidecars decode.
    var customModelRepo: String?
    var caption: IdeogramCaption
    var usePlainPrompt: Bool
    var plainPrompt: String
    var preset: Ideogram4Preset
    var seed: Int
    var width: Int
    var height: Int
    var quantize: Int
    var lowRam: Bool
    /// The LoRA stack, written even when empty so a replay clears the form's
    /// stack. `nil` means a sidecar from before the field: replay keeps the form's.
    var loras: [LoraEntry]?
    var board: String?
    /// Whether PiD decoding produced this image (so the file is 4x the recorded
    /// width/height). Optional and written only when true, so sidecars from
    /// before the field — and every non-PiD generation — stay unchanged.
    var pidDecode: Bool?
    /// Latent degradation for PiD, when non-zero. Recorded even if `pidDecode` was
    /// off for this run, so replaying the image does not silently zero a value the
    /// form was carrying. Omitted at 0 so default runs' sidecars stay unchanged.
    var pidDegradeSigma: Double?
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
            editImagePaths: job.editImagePaths.isEmpty ? nil : job.editImagePaths,
            loras: job.loras,
            board: job.board.isEmpty ? nil : job.board,
            pidDecode: job.pidDecode ? true : nil,
            pidDegradeSigma: job.pidDegradeSigma > 0 ? job.pidDegradeSigma : nil,
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
    /// Reference images of a FLUX.2 Edit. Optional because no sidecar written
    /// before this existed carries it, and `nil` reads back as "not an edit".
    var editImagePaths: [String]?
    var loras: [LoraEntry]
    var board: String?
    /// Whether PiD decoding produced this image (so the file is 4x the recorded
    /// width/height). Optional and written only when true, so sidecars from
    /// before the field — and every non-PiD generation — stay unchanged.
    var pidDecode: Bool?
    /// Latent degradation for PiD, when non-zero. Recorded even if `pidDecode` was
    /// off for this run, so replaying the image does not silently zero a value the
    /// form was carrying. Omitted at 0 so default runs' sidecars stay unchanged.
    var pidDegradeSigma: Double?
    var generatedAt: Date
    var startedAt: Date?
    var log: String?
}

// MARK: - Krea 2 metadata

nonisolated struct Krea2Metadata: Codable {
    /// The value of ``family`` in every Krea 2 sidecar written from now on.
    static let familyTag = "krea2"

    @MainActor static func from(job: Krea2Job) -> Self {
        Self(
            family: familyTag,
            customModelRepo: job.customModelRepo.isEmpty ? nil : job.customModelRepo,
            prompt: job.prompt,
            negativePrompt: job.negativePrompt.isEmpty ? nil : job.negativePrompt,
            seed: job.resolvedSeed ?? job.seed,
            steps: job.steps,
            guidance: job.guidance,
            width: job.width,
            height: job.height,
            quantize: job.quantize,
            lowRam: job.lowRam ? true : nil,
            loras: job.loras,
            imagePath: job.imagePath.isEmpty ? nil : job.imagePath,
            imageStrength: job.imagePath.isEmpty ? nil : job.imageStrength,
            board: job.board.isEmpty ? nil : job.board,
            pidDecode: job.pidDecode ? true : nil,
            pidDegradeSigma: job.pidDegradeSigma > 0 ? job.pidDegradeSigma : nil,
            generatedAt: job.completedAt ?? Date(),
            startedAt: job.startedAt,
            log: job.log.isEmpty ? nil : job.log
        )
    }

    /// Names the family that wrote the sidecar (``familyTag``), so
    /// ``AnySidecar`` need not tell Krea 2 apart by elimination. `nil` in
    /// sidecars written before the field; older builds ignore the key.
    var family: String?
    /// Custom checkpoint this was generated from, when the picker's `Custom…`
    /// entry was loaded as Krea 2. Optional so pre-field sidecars decode.
    var customModelRepo: String?
    var prompt: String
    var negativePrompt: String?
    var seed: Int
    var steps: Int
    var guidance: Double
    var width: Int
    var height: Int
    var quantize: Int
    /// Whether the run streamed blocks with `--low-ram`. Written only when true,
    /// so sidecars from before the field and default runs stay unchanged.
    var lowRam: Bool?
    /// The LoRA stack, written even when empty so a replay clears the form's
    /// stack. `nil` means a sidecar from before the field: replay keeps the form's.
    var loras: [LoraEntry]?
    var imagePath: String?
    var imageStrength: Double?
    var board: String?
    /// Whether PiD decoding produced this image (so the file is 4x the recorded
    /// width/height). Optional and written only when true, so sidecars from
    /// before the field — and every non-PiD generation — stay unchanged.
    var pidDecode: Bool?
    /// Latent degradation for PiD, when non-zero. Recorded even if `pidDecode` was
    /// off for this run, so replaying the image does not silently zero a value the
    /// form was carrying. Omitted at 0 so default runs' sidecars stay unchanged.
    var pidDegradeSigma: Double?
    var generatedAt: Date
    var startedAt: Date?
    var log: String?
}

// MARK: - Z-Image metadata

nonisolated struct ZImageMetadata: Codable {
    @MainActor static func from(job: ZImageJob) -> Self {
        Self(
            modelVariant: job.modelVariant,
            customModelRepo: job.customModelRepo.isEmpty ? nil : job.customModelRepo,
            prompt: job.prompt,
            negativePrompt: job.negativePrompt.isEmpty ? nil : job.negativePrompt,
            seed: job.resolvedSeed ?? job.seed,
            steps: job.steps,
            guidance: job.guidance,
            width: job.width,
            height: job.height,
            quantize: job.quantize,
            loras: job.loras,
            imagePath: job.imagePath.isEmpty ? nil : job.imagePath,
            imageStrength: job.imagePath.isEmpty ? nil : job.imageStrength,
            board: job.board.isEmpty ? nil : job.board,
            pidDecode: job.pidDecode ? true : nil,
            pidDegradeSigma: job.pidDegradeSigma > 0 ? job.pidDegradeSigma : nil,
            generatedAt: job.completedAt ?? Date(),
            startedAt: job.startedAt,
            log: job.log.isEmpty ? nil : job.log
        )
    }

    /// Which Z-Image variant produced the image (Turbo or base). Optional so
    /// sidecars written before the field decode; defaults to Turbo on read.
    var modelVariant: FluxModelVariant?
    /// Custom checkpoint this was generated from, when the picker's `Custom…`
    /// entry was loaded as Z-Image. Optional so pre-field sidecars decode.
    var customModelRepo: String?
    var prompt: String
    var negativePrompt: String?
    var seed: Int
    var steps: Int
    var guidance: Double
    var width: Int
    var height: Int
    var quantize: Int
    /// The LoRA stack, written even when empty so a replay clears the form's
    /// stack. `nil` means a sidecar from before the field: replay keeps the form's.
    var loras: [LoraEntry]?
    var imagePath: String?
    var imageStrength: Double?
    var board: String?
    /// Whether PiD decoding produced this image (so the file is 4x the recorded
    /// width/height). Optional and written only when true, so sidecars from
    /// before the field — and every non-PiD generation — stay unchanged.
    var pidDecode: Bool?
    /// Latent degradation for PiD, when non-zero. Recorded even if `pidDecode` was
    /// off for this run, so replaying the image does not silently zero a value the
    /// form was carrying. Omitted at 0 so default runs' sidecars stay unchanged.
    var pidDegradeSigma: Double?
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
    var qwen21: Qwen21Metadata?
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
        } else if let s = source.qwen21 {
            prompt = s.prompt
            negativePrompt = ""
            sourceModel = FluxModelVariant.qwen21Turbo.displayName
            steps = s.steps
            guidance = 1.0
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
            sourceZImage: source.zimage,
            sourceQwen21: source.qwen21
        )
    }

    /// Reads the source image's sidecar so the upscale can stand on its own once the
    /// original is deleted. If the source is itself an upscale, its own source is
    /// carried forward (``SeedVR2Source/init(_:)``).
    nonisolated static func resolveSource(for sourcePath: String) -> SeedVR2Source {
        SeedVR2Source(AnySidecar.read(forImageAt: sourcePath))
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
    var sourceQwen21: Qwen21Metadata?
}

enum MetadataSidecar {
    static func write(_ metadata: some SidecarMetadata, for imagePath: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: sidecarURL(for: imagePath), options: .atomic)
    }

    /// The sidecar beside `imagePath`, read as `type`. Nil when there is none or
    /// it does not decode as that type; use ``AnySidecar`` to find the family.
    nonisolated static func read<T: SidecarMetadata>(_ type: T.Type, for imagePath: String) -> T? {
        guard let data = try? Data(contentsOf: sidecarURL(for: imagePath)) else { return nil }
        return decode(type, from: data)
    }

    nonisolated static func decode<T: Decodable>(_: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    nonisolated static func sidecarURL(for imagePath: String) -> URL {
        URL(fileURLWithPath: imagePath).deletingPathExtension().appendingPathExtension("json")
    }
}
