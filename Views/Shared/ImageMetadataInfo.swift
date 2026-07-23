import SwiftUI

struct ImageMetadataInfo {
    var prompt: String
    var negativePrompt: String
    var modelName: String
    var seed: Int?
    var width: Int
    var height: Int
    var steps: Int
    var guidance: Double
    var loras: [LoraEntry]
    var filePath: String?
    var log: String?
    var generationTime: String?
    /// Optional qualifier appended to the resolution field, e.g. "from 1024×1024"
    /// for a SeedVR2 upscale so the original (pre-upscale) size stays visible.
    var resolutionNote: String?

    /// Resolution string shown in the grid, with the optional source-size note.
    var resolutionText: String {
        if let note = resolutionNote { return "\(width)×\(height) (\(note))" }
        return "\(width)×\(height)"
    }

    init(job: FluxJob) {
        prompt = job.prompt
        negativePrompt = job.negativePrompt
        modelName = job.model == .custom ? "Custom" : job.model.displayName
        seed = job.resolvedSeed
        width = job.width
        height = job.height
        steps = job.steps
        guidance = job.guidance
        loras = job.loras
        filePath = job.outputPath
        log = job.log.isEmpty ? nil : job.log
        if job.seeds.isEmpty, let started = job.startedAt, let ended = job.completedAt {
            let secs = Int(ended.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init?(item: GalleryItem) {
        guard let meta = item.metadata else { return nil }
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt
        modelName = meta.model == .custom ? "Custom" : meta.model.displayName
        seed = meta.seed
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        loras = meta.loras
        filePath = item.path
        log = meta.log
        if let started = meta.startedAt {
            let secs = Int(meta.generatedAt.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init(ideogram4Job job: Ideogram4Job) {
        prompt = job.usePlainPrompt ? job.plainPrompt : job.caption.highLevelDescription
        negativePrompt = ""
        modelName = "Ideogram 4"
        seed = job.resolvedSeed ?? job.seed
        width = job.width
        height = job.height
        steps = job.preset.stepCount
        guidance = 1.0
        loras = job.loras
        filePath = job.outputPath
        log = job.log.isEmpty ? nil : job.log
        if let started = job.startedAt, let ended = job.completedAt {
            let secs = Int(ended.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init(ideogram4Item: GalleryItem) {
        let meta = ideogram4Item.ideogram4Metadata
        if meta?.usePlainPrompt == true {
            prompt = meta?.plainPrompt ?? ""
        } else {
            prompt = meta?.caption.highLevelDescription ?? ""
        }
        negativePrompt = ""
        modelName = "Ideogram 4"
        seed = meta?.seed
        width = meta?.width ?? 0
        height = meta?.height ?? 0
        steps = meta?.preset.stepCount ?? 0
        guidance = 1.0
        loras = meta?.loras ?? []
        filePath = ideogram4Item.path
        log = meta?.log
        if let started = meta?.startedAt, let generatedAt = meta?.generatedAt {
            let secs = Int(generatedAt.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        } else {
            generationTime = nil
        }
    }

    init(krea2Job job: Krea2Job) {
        prompt = job.prompt
        negativePrompt = job.guidance != 1.0 ? job.negativePrompt : ""
        modelName = "Krea 2 Turbo"
        seed = job.resolvedSeed ?? job.seed
        width = job.width
        height = job.height
        steps = job.steps
        guidance = job.guidance
        loras = job.loras
        filePath = job.outputPath
        log = job.log.isEmpty ? nil : job.log
        if job.seeds.isEmpty, let started = job.startedAt, let ended = job.completedAt {
            let secs = Int(ended.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init?(krea2Item: GalleryItem) {
        guard let meta = krea2Item.krea2Metadata else { return nil }
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt ?? ""
        modelName = "Krea 2 Turbo"
        seed = meta.seed
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        loras = meta.loras ?? []
        filePath = krea2Item.path
        log = meta.log
        if let started = meta.startedAt {
            let secs = Int(meta.generatedAt.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init(zimageJob job: ZImageJob) {
        prompt = job.prompt
        negativePrompt = job.isTurbo ? "" : job.negativePrompt
        modelName = job.modelVariant.displayName
        seed = job.resolvedSeed ?? job.seed
        width = job.width
        height = job.height
        steps = job.steps
        guidance = job.guidance
        loras = job.loras
        filePath = job.outputPath
        log = job.log.isEmpty ? nil : job.log
        if job.seeds.isEmpty, let started = job.startedAt, let ended = job.completedAt {
            let secs = Int(ended.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init?(zimageItem: GalleryItem) {
        guard let meta = zimageItem.zimageMetadata else { return nil }
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt ?? ""
        modelName = meta.resolvedVariant.displayName
        seed = meta.seed
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        loras = meta.loras ?? []
        filePath = zimageItem.path
        log = meta.log
        if let started = meta.startedAt {
            let secs = Int(meta.generatedAt.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init?(seedVR2Item: GalleryItem) {
        guard let meta = seedVR2Item.seedVR2Metadata else { return nil }
        let modelLabel = meta.model == "seedvr2-7b" ? "SeedVR2 7B" : "SeedVR2 3B"
        let upscaleLabel = "\(modelLabel) · \(meta.scale)×"
        width = meta.width
        height = meta.height
        filePath = seedVR2Item.path
        log = meta.log
        // Source-forward: surface the original prompt/loras/recipe (it's the same
        // image, just larger) with the upscale noted in the model line.
        let source = SeedVR2Source(
            flux: meta.sourceFlux, ideogram4: meta.sourceIdeogram4, krea2: meta.sourceKrea2
        )
        if let src = SeedVR2DisplayFields(source: source) {
            prompt = src.prompt
            negativePrompt = src.negativePrompt
            modelName = "\(upscaleLabel) ← \(src.sourceModel)"
            seed = src.seed
            steps = src.steps
            guidance = src.guidance
            loras = src.loras
            resolutionNote = "from \(src.width)×\(src.height)"
        } else {
            // Pre-inheritance sidecar (or a source that carried none): show the
            // upscale parameters directly, as before.
            prompt = "Upscale \(meta.scale)× · softness \(String(format: "%.2f", meta.softness))"
            negativePrompt = ""
            modelName = modelLabel
            seed = meta.seed
            steps = 0
            guidance = 1.0
            loras = []
        }
        if let started = meta.startedAt {
            let secs = Int(meta.generatedAt.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        } else {
            generationTime = nil
        }
    }

    init(seedVR2Job job: SeedVR2Job) {
        let upscaleLabel = "\(job.modelLabel) · \(job.scale)×"
        width = job.width
        height = job.height
        filePath = job.outputPath
        log = job.log.isEmpty ? nil : job.log
        let source = SeedVR2Metadata.resolveSource(for: job.sourcePath)
        if let src = SeedVR2DisplayFields(source: source) {
            prompt = src.prompt
            negativePrompt = src.negativePrompt
            modelName = "\(upscaleLabel) ← \(src.sourceModel)"
            seed = src.seed
            steps = src.steps
            guidance = src.guidance
            loras = src.loras
            resolutionNote = "from \(src.width)×\(src.height)"
        } else {
            prompt = "Upscale \(job.scale)× · softness \(String(format: "%.2f", job.softness))"
            negativePrompt = ""
            modelName = job.modelLabel
            seed = job.resolvedSeed ?? job.seed
            steps = 0
            guidance = 1.0
            loras = []
        }
        if let started = job.startedAt, let ended = job.completedAt {
            let secs = Int(ended.timeIntervalSince(started))
            generationTime = "\(secs / 60)m \(secs % 60)s"
        }
    }

    init(path: String) {
        prompt = ""; negativePrompt = ""; modelName = "Unknown"
        seed = nil; width = 0; height = 0; steps = 0; guidance = 1.0; loras = []
        filePath = path; log = nil; generationTime = nil
    }
}
