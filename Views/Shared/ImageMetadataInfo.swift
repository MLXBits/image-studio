import ImageIO
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

    /// Pixel count in megapixels, e.g. "1.3 MP". Sub-megapixel sizes get a second
    /// decimal so 512×512 reads "0.26 MP" rather than rounding to "0.3 MP".
    var megapixelText: String {
        let mp = Double(width * height) / 1_000_000
        return String(format: mp < 1 ? "%.2f MP" : "%.1f MP", mp)
    }

    /// Resolution string shown in the grid, with the optional source-size note.
    var resolutionText: String {
        // `init(path:)` has no metadata to read, so leave the 0×0 placeholder bare.
        let base = width > 0 && height > 0
            ? "\(width)×\(height) · \(megapixelText)"
            : "\(width)×\(height)"
        if let note = resolutionNote {
            return "\(base) (\(note))"
        }
        return base
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
        applyPidUpscale(job.pidDecode, degradeSigma: job.pidDegradeSigma)
        log = job.log.isEmpty ? nil : job.log
        if job.seeds.isEmpty {
            generationTime = Self.elapsed(from: job.startedAt, to: job.completedAt)
        }
    }

    init(flux meta: GenerationMetadata, path: String) {
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt
        modelName = meta.model == .custom ? "Custom" : meta.model.displayName
        seed = meta.seed
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        loras = meta.loras
        filePath = path
        applyPidUpscale(meta.pidDecode ?? false, degradeSigma: meta.pidDegradeSigma)
        log = meta.log
        generationTime = Self.elapsed(from: meta.startedAt, to: meta.generatedAt)
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
        applyPidUpscale(job.pidDecode, degradeSigma: job.pidDegradeSigma)
        log = job.log.isEmpty ? nil : job.log
        generationTime = Self.elapsed(from: job.startedAt, to: job.completedAt)
    }

    init(ideogram4 meta: Ideogram4Metadata, path: String) {
        prompt = meta.usePlainPrompt ? meta.plainPrompt : meta.caption.highLevelDescription
        negativePrompt = ""
        modelName = "Ideogram 4"
        seed = meta.seed
        width = meta.width
        height = meta.height
        steps = meta.preset.stepCount
        guidance = 1.0
        loras = meta.loras ?? []
        filePath = path
        applyPidUpscale(meta.pidDecode ?? false, degradeSigma: meta.pidDegradeSigma)
        log = meta.log
        generationTime = Self.elapsed(from: meta.startedAt, to: meta.generatedAt)
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
        applyPidUpscale(job.pidDecode, degradeSigma: job.pidDegradeSigma)
        log = job.log.isEmpty ? nil : job.log
        if job.seeds.isEmpty {
            generationTime = Self.elapsed(from: job.startedAt, to: job.completedAt)
        }
    }

    init(krea2 meta: Krea2Metadata, path: String) {
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt ?? ""
        modelName = "Krea 2 Turbo"
        seed = meta.seed
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        loras = meta.loras ?? []
        filePath = path
        applyPidUpscale(meta.pidDecode ?? false, degradeSigma: meta.pidDegradeSigma)
        log = meta.log
        generationTime = Self.elapsed(from: meta.startedAt, to: meta.generatedAt)
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
        applyPidUpscale(job.pidDecode, degradeSigma: job.pidDegradeSigma)
        log = job.log.isEmpty ? nil : job.log
        if job.seeds.isEmpty {
            generationTime = Self.elapsed(from: job.startedAt, to: job.completedAt)
        }
    }

    init(zimage meta: ZImageMetadata, path: String) {
        prompt = meta.prompt
        negativePrompt = meta.negativePrompt ?? ""
        modelName = meta.resolvedVariant.displayName
        seed = meta.seed
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = meta.guidance
        loras = meta.loras ?? []
        filePath = path
        applyPidUpscale(meta.pidDecode ?? false, degradeSigma: meta.pidDegradeSigma)
        log = meta.log
        generationTime = Self.elapsed(from: meta.startedAt, to: meta.generatedAt)
    }

    init(seedVR2 meta: SeedVR2Metadata, path: String) {
        let modelLabel = meta.model == "seedvr2-7b" ? "SeedVR2 7B" : "SeedVR2 3B"
        let upscaleLabel = "\(modelLabel) · \(meta.scale)×"
        width = meta.width
        height = meta.height
        filePath = path
        log = meta.log
        // Source-forward: surface the original prompt/loras/recipe (it's the same
        // image, just larger) with the upscale noted in the model line.
        if let src = SeedVR2DisplayFields(source: SeedVR2Source(.seedVR2(meta))) {
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
        generationTime = Self.elapsed(from: meta.startedAt, to: meta.generatedAt)
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
        generationTime = Self.elapsed(from: job.startedAt, to: job.completedAt)
    }

    @MainActor init(qwen21Job job: Qwen21Job) {
        var meta = Qwen21Metadata.from(job: job)
        meta.seed = job.resolvedSeed ?? job.seed
        self.init(qwen21: meta, path: job.outputPath)
        if !job.seeds.isEmpty {
            generationTime = nil // a batch's start/end span every seed
        }
    }

    init(qwen21 meta: Qwen21Metadata, path: String?) {
        prompt = meta.prompt
        negativePrompt = ""
        let refs = meta.editImagePaths?.count ?? 0
        modelName = FluxModelVariant.qwen21Turbo.displayName + (meta.isEditMode ? " · Edit, \(refs) ref" : "")
        seed = meta.seed
        width = meta.width
        height = meta.height
        steps = meta.steps
        guidance = 1.0
        loras = meta.loras ?? []
        filePath = path
        log = meta.log
        // An edit that followed its references: the form size isn't the output size.
        if meta.matchReferenceSize == true, let path, let size = imagePixelSize(at: path) {
            (width, height) = size
        }
        generationTime = Self.elapsed(from: meta.startedAt, to: meta.generatedAt)
    }

    init(path: String) {
        prompt = ""; negativePrompt = ""; modelName = "Unknown"
        seed = nil; width = 0; height = 0; steps = 0; guidance = 1.0; loras = []
        filePath = path; log = nil; generationTime = nil
    }

    /// Re-points the resolution fields at the file actually on disk when PiD
    /// decoded it. The recorded width/height are the *generation* size — PiD emits
    /// 4x that — so show the real dimensions with the source size noted, which is
    /// how a SeedVR2 upscale already reads.
    private mutating func applyPidUpscale(_ pidDecode: Bool, degradeSigma: Double? = nil) {
        guard pidDecode, width > 0, height > 0 else { return }
        var note = "PiD \(PidDecode.scaleFactor)× from \(width)×\(height)"
        // Only when it applied: a run at 0 is the default and adds nothing to read.
        if let degradeSigma, degradeSigma > 0 {
            note += String(format: ", degrade σ %.2f", degradeSigma)
        }
        resolutionNote = note
        width *= PidDecode.scaleFactor
        height *= PidDecode.scaleFactor
    }
}

/// Reads only the file header, not the pixels.
/// An image's pixel size as displayed: EXIF orientations 5–8 (rotated 90°) swap width and height.
func imagePixelSize(at path: String) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
    return orientation >= 5 ? (h, w) : (w, h)
}

extension ImageMetadataInfo {
    /// The info for a gallery image, from whichever family's sidecar it has; an
    /// image without one shows only what the file itself says.
    init(galleryItem item: GalleryItem) {
        self = switch item.sidecar {
        case let .flux(meta): ImageMetadataInfo(flux: meta, path: item.path)
        case let .ideogram4(meta): ImageMetadataInfo(ideogram4: meta, path: item.path)
        case let .krea2(meta): ImageMetadataInfo(krea2: meta, path: item.path)
        case let .zimage(meta): ImageMetadataInfo(zimage: meta, path: item.path)
        case let .qwen21(meta): ImageMetadataInfo(qwen21: meta, path: item.path)
        case let .seedVR2(meta): ImageMetadataInfo(seedVR2: meta, path: item.path)
        case nil: ImageMetadataInfo(path: item.path)
        }
    }
}

extension ImageMetadataInfo {
    /// The Time row: whole minutes and seconds from `started` to `ended`, or nil
    /// when either is unknown (sidecars from before start times were recorded).
    static func elapsed(from started: Date?, to ended: Date?) -> String? {
        guard let started, let ended else { return nil }
        let secs = Int(ended.timeIntervalSince(started))
        return "\(secs / 60)m \(secs % 60)s"
    }
}
