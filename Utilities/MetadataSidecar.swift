import Foundation

struct GenerationMetadata: Codable {
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
    var generatedAt: Date
    var log: String?

    static func from(job: FluxJob) -> GenerationMetadata {
        GenerationMetadata(
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
            generatedAt: job.completedAt ?? Date(),
            log: job.log.isEmpty ? nil : job.log
        )
    }
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

    static func read(for imagePath: String) -> GenerationMetadata? {
        let url = sidecarURL(for: imagePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GenerationMetadata.self, from: data)
    }

    static func sidecarURL(for imagePath: String) -> URL {
        URL(fileURLWithPath: imagePath).deletingPathExtension().appendingPathExtension("json")
    }
}
