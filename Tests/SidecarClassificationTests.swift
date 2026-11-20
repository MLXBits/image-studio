import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Which family a sidecar belongs to, as the gallery (``GallerySidecars``) and a
/// SeedVR2 upscale (``SeedVR2Metadata/resolveSource(for:)``) work it out.
///
/// The fixtures are the oldest sidecars each family wrote: the required fields
/// only. Fields added later are optional, so these must keep decoding.
@Suite("Sidecar classification")
struct SidecarClassificationTests {
    nonisolated private enum Family: String, CaseIterable {
        case flux, ideogram4, krea2, zimage, qwen21, seedVR2
    }

    nonisolated private struct Fixture {
        let file: String
        let json: String
        let family: Family
    }

    nonisolated private static let flux = """
    {"prompt": "a cat", "negativePrompt": "", "model": "flux2-klein-9b", "customModelRepo": "",
     "customBaseModel": "flux2-klein-9b", "seed": 1, "steps": 4, "guidance": 1.0, "width": 1024,
     "height": 1024, "quantize": 8, "lowRam": false, "imagePath": "", "imageStrength": 0.75,
     "loras": [{"path": "/l.safetensors", "strength": 0.8}], "generatedAt": "2026-06-01T10:00:00Z"}
    """

    nonisolated private static let ideogram4 = """
    {"caption": {"high_level_description": "a lighthouse",
                 "compositional_deconstruction": {"background": "sea", "elements": []}},
     "usePlainPrompt": false, "plainPrompt": "", "preset": "V4_DEFAULT_20", "seed": 2, "width": 1024,
     "height": 1024, "quantize": 0, "lowRam": false, "generatedAt": "2026-06-10T10:00:00Z"}
    """

    /// Krea 2 and Z-Image wrote the same required fields: only the file name
    /// tells these two apart.
    nonisolated private static let krea2OrZImage = """
    {"prompt": "a fox", "seed": 3, "steps": 9, "guidance": 1.0, "width": 1024, "height": 1024,
     "quantize": 8, "generatedAt": "2026-07-01T10:00:00Z"}
    """

    nonisolated private static let qwen21 = """
    {"isEditMode": false, "prompt": "a bird", "steps": 8, "quantize": 8, "width": 1024, "height": 1024,
     "seed": 4, "generatedAt": "2026-11-01T10:00:00Z"}
    """

    nonisolated private static let seedVR2OfKrea2 = """
    {"sourcePath": "/out/krea2_1.png", "model": "seedvr2-3b", "scale": 2, "softness": 0.0, "quantize": 8,
     "seed": 5, "width": 2048, "height": 2048, "generatedAt": "2026-10-01T10:00:00Z",
     "sourceKrea2": \(krea2OrZImage)}
    """

    /// Nonisolated: test arguments are built off the main actor.
    nonisolated private static let oldSidecars = [
        Fixture(file: "image_1748772000_1.png", json: flux, family: .flux),
        Fixture(file: "ideogram4_1749549600_2.png", json: ideogram4, family: .ideogram4),
        Fixture(file: "krea2_1751364000_3.png", json: krea2OrZImage, family: .krea2),
        Fixture(file: "zimage_1751364000_3.png", json: krea2OrZImage, family: .zimage),
        Fixture(file: "qwen21_1761991200_4.png", json: qwen21, family: .qwen21),
    ]

    // MARK: - Helpers

    private static func families(_ found: GallerySidecars) -> [Family] {
        let present: [(Family, Bool)] = [
            (.flux, found.flux != nil), (.ideogram4, found.ideogram4 != nil), (.krea2, found.krea2 != nil),
            (.zimage, found.zimage != nil), (.qwen21, found.qwen21 != nil), (.seedVR2, found.seedVR2 != nil),
        ]
        return present.filter(\.1).map(\.0)
    }

    private static func families(_ source: SeedVR2Source) -> [Family] {
        families(GallerySidecars(
            flux: source.flux, ideogram4: source.ideogram4, krea2: source.krea2,
            zimage: source.zimage, qwen21: source.qwen21
        ))
    }

    /// Writes `json` as the sidecar of an image called `fileName`, in a fresh
    /// folder, and returns the image path. The image itself need not exist.
    private func image(_ fileName: String, sidecar json: String?) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(fileName).path
        if let json {
            try Data(json.utf8).write(to: MetadataSidecar.sidecarURL(for: path))
        }
        return path
    }

    private func classify(_ fileName: String, _ json: String?) throws -> [Family] {
        let path = try image(fileName, sidecar: json)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        return Self.families(GallerySidecars.read(forImageAt: path))
    }

    private func resolve(_ fileName: String, _ json: String?) throws -> [Family] {
        let path = try image(fileName, sidecar: json)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        return Self.families(SeedVR2Metadata.resolveSource(for: path))
    }

    // MARK: - Old sidecars

    @Test(arguments: oldSidecars.indices)
    func theGalleryReadsEachOldSidecarAsItsFamily(_ index: Int) throws {
        let fixture = Self.oldSidecars[index]
        #expect(try classify(fixture.file, fixture.json) == [fixture.family])
    }

    /// An upscale records its source's settings: it must agree with the gallery.
    @Test(arguments: oldSidecars.indices)
    func anUpscaleReadsEachOldSourceAsItsFamily(_ index: Int) throws {
        let fixture = Self.oldSidecars[index]
        #expect(try resolve(fixture.file, fixture.json) == [fixture.family])
    }

    @Test func theGalleryReadsAnUpscaleSidecar() throws {
        #expect(try classify("seedvr2_1759312800_5.png", Self.seedVR2OfKrea2) == [.seedVR2])
    }

    /// Upscaling an upscale carries the original source forward, one hop.
    @Test func upscalingAnUpscaleKeepsTheOriginalSource() throws {
        #expect(try resolve("seedvr2_1759312800_5.png", Self.seedVR2OfKrea2) == [.krea2])
    }

    // MARK: - The Krea 2 / Z-Image ambiguity

    /// A renamed Z-Image file loses its prefix, and its sidecar then reads as
    /// Krea 2: the two shapes are the same. The prefix is the only signal.
    @Test func withoutItsPrefixAZImageSidecarReadsAsKrea2() throws {
        #expect(try classify("renamed.png", Self.krea2OrZImage) == [.krea2])
        #expect(try resolve("renamed.png", Self.krea2OrZImage) == [.krea2])
    }

    /// A file named like Z-Image whose sidecar does not decode as Z-Image still
    /// gets read as its own family.
    @Test func aZImagePrefixDoesNotHideAnotherFamily() throws {
        #expect(try classify("zimage_copy.png", Self.ideogram4) == [.ideogram4])
    }

    /// The prefix wins over shape: a Flux sidecar carries every field Z-Image
    /// requires, so beside a `zimage` file it reads as Z-Image. Only a hand-renamed
    /// file can get here; the app never writes a Flux image under that prefix.
    @Test func aZImagePrefixClaimsAFluxShapedSidecar() throws {
        #expect(try classify("zimage_copy.png", Self.flux) == [.zimage])
        #expect(try resolve("zimage_copy.png", Self.flux) == [.zimage])
    }

    @Test func aQwenPrefixDoesNotHideAnotherFamily() throws {
        #expect(try classify("qwen21_copy.png", Self.flux) == [.flux])
    }

    /// Qwen's sidecar has no `guidance`, so it never reads as Krea 2 or Z-Image.
    /// The gallery reads it only by its prefix, while an upscale falls back to a
    /// plain decode: the two disagree on a renamed file (Batch 8 unifies them).
    @Test func aRenamedQwenImageIsReadOnlyByAnUpscale() throws {
        #expect(try classify("renamed.png", Self.qwen21).isEmpty)
        #expect(try resolve("renamed.png", Self.qwen21) == [.qwen21])
    }

    // MARK: - Current sidecars

    /// What today's build writes reads back as the family that wrote it.
    @Test func currentSidecarsReadBackAsTheirFamily() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func path(_ name: String) -> String {
            dir.appendingPathComponent(name).path
        }

        let lora = LoraEntry(path: "/l.safetensors")
        MetadataSidecar.write(.from(job: FluxJob(prompt: "f", negativePrompt: "n", loras: [lora])), for: path("image_1.png"))
        MetadataSidecar.writeIdeogram4(.from(job: Ideogram4Job(plainPrompt: "i")), for: path("ideogram4_1.png"))
        MetadataSidecar.writeKrea2(.from(job: Krea2Job(prompt: "k", negativePrompt: "n")), for: path("krea2_1.png"))
        MetadataSidecar.writeZImage(.from(job: ZImageJob(modelVariant: .zimage, prompt: "z")), for: path("zimage_1.png"))
        MetadataSidecar.writeQwen21(.from(job: Qwen21Job(prompt: "q")), for: path("qwen21_1.png"))

        #expect(Self.families(GallerySidecars.read(forImageAt: path("image_1.png"))) == [.flux])
        #expect(Self.families(GallerySidecars.read(forImageAt: path("ideogram4_1.png"))) == [.ideogram4])
        #expect(Self.families(GallerySidecars.read(forImageAt: path("krea2_1.png"))) == [.krea2])
        let zimage = GallerySidecars.read(forImageAt: path("zimage_1.png"))
        #expect(Self.families(zimage) == [.zimage])
        #expect(zimage.zimage?.resolvedVariant == .zimage)
        #expect(Self.families(GallerySidecars.read(forImageAt: path("qwen21_1.png"))) == [.qwen21])
    }

    // MARK: - No usable sidecar

    @Test func anImageWithoutASidecarHasNoMetadata() throws {
        #expect(try classify("image_1.png", nil).isEmpty)
        #expect(try resolve("image_1.png", nil).isEmpty)
    }

    @Test func aDamagedSidecarHasNoMetadata() throws {
        #expect(try classify("image_1.png", #"{"prompt": "cut off"#).isEmpty)
    }

    /// A Flux sidecar naming a model this build does not know (written by a newer
    /// build, or a model since removed) fails the Flux decode, and then has every
    /// field Krea 2 requires. It should read as no family; today it reads as Krea 2.
    /// Batch 8's single sidecar classifier is where this gets fixed.
    @Test func aFluxSidecarWithAnUnknownModelIsNotClaimedByKrea2() throws {
        let json = Self.flux.replacingOccurrences(of: #""model": "flux2-klein-9b""#, with: #""model": "flux9-ultra""#)
        let gallery = try classify("image_1.png", json)
        let upscale = try resolve("image_1.png", json)
        withKnownIssue("A Flux sidecar with an unknown model is read as Krea 2") {
            #expect(gallery.isEmpty)
            #expect(upscale.isEmpty)
        }
    }
}
