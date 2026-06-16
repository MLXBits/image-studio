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

    nonisolated static func sidecarURL(for imagePath: String) -> URL {
        URL(fileURLWithPath: imagePath).deletingPathExtension().appendingPathExtension("json")
    }
}
