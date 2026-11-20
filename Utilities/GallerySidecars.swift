import Foundation

/// The sidecar metadata the gallery reads for one image. At most one family is
/// non-nil, or none when the image has no sidecar (or one no family decodes).
nonisolated struct GallerySidecars {
    /// Reads the sidecar beside `imagePath` and works out which family wrote it
    /// (``AnySidecar/classify(data:fileName:)``).
    static func read(forImageAt imagePath: String) -> Self {
        Self(AnySidecar.read(forImageAt: imagePath))
    }

    var flux: GenerationMetadata?
    var ideogram4: Ideogram4Metadata?
    var krea2: Krea2Metadata?
    var zimage: ZImageMetadata?
    var qwen21: Qwen21Metadata?
    var seedVR2: SeedVR2Metadata?
}
