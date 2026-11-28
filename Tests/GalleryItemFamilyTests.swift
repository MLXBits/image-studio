import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The gallery shows only the picked family's images. An image's family comes
/// from its file name; an upscale's from the image it was made from.
@MainActor
struct GalleryItemFamilyTests {
    private func item(_ name: String, sidecar: AnySidecar? = nil) -> GalleryItem {
        GalleryItem(
            id: UUID(), path: "/out/\(name)", board: "Default", modifiedAt: Date(timeIntervalSince1970: 0),
            sidecar: sidecar, searchHaystack: ""
        )
    }

    private func upscale(sourcePath: String = "", source: AnySidecar? = nil) -> AnySidecar {
        var meta = SeedVR2Metadata.from(job: SeedVR2Job(sourcePath: sourcePath))
        let found = SeedVR2Source(source)
        meta.sourceFlux = found.flux
        meta.sourceIdeogram4 = found.ideogram4
        meta.sourceKrea2 = found.krea2
        meta.sourceZImage = found.zimage
        meta.sourceQwen21 = found.qwen21
        return .seedVR2(meta)
    }

    @Test(arguments: [
        ("image_1.png", ModelFamily.flux), ("renamed.png", .flux),
        ("ideogram4_1.png", .ideogram4), ("ideogram_1.png", .ideogram4),
        ("krea2_1.png", .krea2), ("zimage_1.png", .zimage), ("qwen21_1.png", .qwen21),
        ("KREA2_1.png", .krea2),
    ])
    func anImageIsInTheFamilyItsNameSays(name: String, family: ModelFamily) {
        #expect(item(name).modelFamily == family)
    }

    private func generation(of family: ModelFamily) -> AnySidecar? {
        switch family {
        case .flux: .flux(GenerationMetadata.from(job: FluxJob(prompt: "a")))
        case .ideogram4: .ideogram4(Ideogram4Metadata.from(job: Ideogram4Job()))
        case .krea2: .krea2(Krea2Metadata.from(job: Krea2Job(prompt: "a")))
        case .zimage: .zimage(ZImageMetadata.from(job: ZImageJob(prompt: "a")))
        case .qwen21: .qwen21(Qwen21Metadata.from(job: Qwen21Job(prompt: "a")))
        case .seedvr2: nil
        }
    }

    @Test(arguments: [ModelFamily.flux, .ideogram4, .krea2, .zimage, .qwen21])
    func anUpscaleIsInItsSourcesFamily(family: ModelFamily) {
        #expect(item("seedvr2_1.png", sidecar: upscale(source: generation(of: family))).modelFamily == family)
    }

    /// The first family whose prefix a name starts with claims it, so no prefix
    /// may start with another's: "ideogram5_" would land in Ideogram 4.
    @Test func noGalleryPrefixShadowsAnother() {
        let prefixes = ModelFamily.allCases.compactMap(\.galleryFilePrefix)
        for a in prefixes {
            for b in prefixes where a != b {
                #expect(!b.hasPrefix(a), "\(b) starts with \(a)")
            }
        }
    }

    /// An upscale's sidecar from before it carried its source names the source file.
    @Test func anOldUpscaleIsInItsSourceFilesFamily() {
        #expect(item("seedvr2_1.png", sidecar: upscale(sourcePath: "/out/qwen21_1.png")).modelFamily == .qwen21)
        #expect(item("seedvr2_1.png", sidecar: upscale(sourcePath: "/out/seedvr2_0.png")).modelFamily == .flux)
        #expect(item("seedvr2_1.png").modelFamily == .flux)
    }

    @Test func eachSidecarKnowsItsFamily() {
        #expect(AnySidecar.krea2(Krea2Metadata.from(job: Krea2Job(prompt: "a"))).family == .krea2)
        #expect(upscale().family == .seedvr2)
    }
}
