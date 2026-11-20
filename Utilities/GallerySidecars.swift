import Foundation

/// The sidecar metadata the gallery reads for one image. At most one family is
/// non-nil, or none when the image has no sidecar (or one no family decodes).
nonisolated struct GallerySidecars {
    /// Reads the sidecar beside `imagePath` and works out which family wrote it.
    ///
    /// Z-Image is probed by filename prefix first: its sidecar shares the Krea 2
    /// shape closely enough that a blind decode would mis-claim it. Qwen-Image 2.1
    /// is read only by its prefix too, and then nothing else is tried.
    static func read(forImageAt imagePath: String) -> Self {
        let lowered = (imagePath as NSString).lastPathComponent.lowercased()
        var found = Self()
        found.qwen21 = lowered.hasPrefix("qwen21") ? MetadataSidecar.readQwen21(for: imagePath) : nil
        found.zimage = lowered.hasPrefix("zimage") ? MetadataSidecar.readZImage(for: imagePath) : nil
        guard found.zimage == nil, found.qwen21 == nil else { return found }
        if let flux = MetadataSidecar.read(for: imagePath) {
            found.flux = flux
        } else if let ideogram4 = MetadataSidecar.readIdeogram4(for: imagePath) {
            found.ideogram4 = ideogram4
        } else if let krea2 = MetadataSidecar.readKrea2(for: imagePath) {
            found.krea2 = krea2
        } else {
            found.seedVR2 = MetadataSidecar.readSeedVR2(for: imagePath)
        }
        return found
    }

    var flux: GenerationMetadata?
    var ideogram4: Ideogram4Metadata?
    var krea2: Krea2Metadata?
    var zimage: ZImageMetadata?
    var qwen21: Qwen21Metadata?
    var seedVR2: SeedVR2Metadata?
}
