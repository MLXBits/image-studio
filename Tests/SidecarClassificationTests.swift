import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Which family a sidecar belongs to, as ``AnySidecar/classify(data:fileName:)``
/// works it out for both the gallery (``AnySidecar/read(forImageAt:)``) and a SeedVR2 upscale
/// (``SeedVR2Metadata/resolveSource(for:)``).
///
/// The fixtures are the oldest sidecars each family wrote: the required fields
/// only. Fields added later are optional, so these must keep decoding.
@Suite("Sidecar classification")
struct SidecarClassificationTests {
    /// Raw values are the family tags sidecars carry.
    nonisolated private enum Family: String, CaseIterable {
        case flux, ideogram4, krea2, zimage, qwen21
        case seedVR2 = "seedvr2"
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

    /// Krea 2 and Z-Image wrote the same required fields, and Z-Image sidecars from
    /// before `modelVariant` have no key of their own: only the file name tells
    /// these two apart.
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

    /// Each family's sidecar with its family tag, as this build writes them.
    nonisolated private static let taggedSidecars = (oldSidecars + [
        Fixture(file: "seedvr2_1759312800_5.png", json: seedVR2OfKrea2, family: .seedVR2),
    ]).map { Fixture(file: $0.file, json: tagged($0.json, $0.family.rawValue), family: $0.family) }

    // MARK: - Helpers

    nonisolated private static func tagged(_ json: String, _ tag: String) -> String {
        "{\"family\": \"\(tag)\", " + json.dropFirst()
    }

    private static func families(_ found: AnySidecar?) -> [Family] {
        found.flatMap { Family(rawValue: $0.family.rawValue) }.map { [$0] } ?? []
    }

    private static func families(_ source: SeedVR2Source) -> [Family] {
        let present: [(Family, Bool)] = [
            (.flux, source.flux != nil), (.ideogram4, source.ideogram4 != nil), (.krea2, source.krea2 != nil),
            (.zimage, source.zimage != nil), (.qwen21, source.qwen21 != nil),
        ]
        return present.filter(\.1).map(\.0)
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
        return Self.families(AnySidecar.read(forImageAt: path))
    }

    private func resolve(_ fileName: String, _ json: String?) throws -> [Family] {
        let path = try image(fileName, sidecar: json)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        return Self.families(SeedVR2Metadata.resolveSource(for: path))
    }

    // MARK: - Untagged sidecars (the legacy fallback)

    // Everything from here to "Family tag" covers sidecars written before the
    // tag: the key checks and file prefixes in `AnySidecar.legacyFamily`.

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

    /// A renamed old Z-Image file loses its prefix, and its sidecar then reads as
    /// Krea 2: the two shapes are the same. The prefix is the only signal.
    @Test func withoutItsPrefixAnOldZImageSidecarReadsAsKrea2() throws {
        #expect(try classify("renamed.png", Self.krea2OrZImage) == [.krea2])
        #expect(try resolve("renamed.png", Self.krea2OrZImage) == [.krea2])
    }

    /// Today's Z-Image sidecars record `modelVariant`, which no other family
    /// writes, so a renamed one still reads as Z-Image.
    @Test func aRenamedZImageWithItsVariantReadsAsZImage() throws {
        let json = Self.krea2OrZImage.replacingOccurrences(of: "{", with: #"{"modelVariant": "z-image", "#)
        #expect(try classify("renamed.png", json) == [.zimage])
        #expect(try resolve("renamed.png", json) == [.zimage])
    }

    /// A file named like Z-Image whose sidecar does not decode as Z-Image still
    /// gets read as its own family.
    @Test func aZImagePrefixDoesNotHideAnotherFamily() throws {
        #expect(try classify("zimage_copy.png", Self.ideogram4) == [.ideogram4])
    }

    /// Shape wins over the prefix: a Flux sidecar carries every field Z-Image
    /// requires, but also `customBaseModel`, which only Flux writes. Only a
    /// hand-renamed file can get here.
    @Test func aZImagePrefixDoesNotClaimAFluxSidecar() throws {
        #expect(try classify("zimage_copy.png", Self.flux) == [.flux])
        #expect(try resolve("zimage_copy.png", Self.flux) == [.flux])
    }

    @Test func aQwenPrefixDoesNotHideAnotherFamily() throws {
        #expect(try classify("qwen21_copy.png", Self.flux) == [.flux])
    }

    /// Qwen's sidecar records `isEditMode`, which no other family writes, so a
    /// renamed Qwen image reads as Qwen in the gallery and in an upscale alike.
    @Test func aRenamedQwenImageReadsAsQwen() throws {
        #expect(try classify("renamed.png", Self.qwen21) == [.qwen21])
        #expect(try resolve("renamed.png", Self.qwen21) == [.qwen21])
    }

    // MARK: - Family tag

    /// A tagged sidecar reads as its tag says, whatever the file is called:
    /// no prefix, and no other family's prefix, changes it.
    @Test(arguments: taggedSidecars.indices)
    func aTaggedSidecarReadsAsItsFamilyUnderAnyName(_ index: Int) throws {
        let fixture = Self.taggedSidecars[index]
        for name in ["renamed.png", "zimage_copy.png", "qwen21_copy.png", "krea2_copy.png"] {
            #expect(try classify(name, fixture.json) == [fixture.family], "\(name)")
        }
    }

    /// The tag decides before any key is looked at, so a field a family adds
    /// later under a name another family uses cannot move it to that family.
    @Test func theTagWinsOverEveryOtherFamilysKey() throws {
        let json = Self.tagged(Self.krea2OrZImage, "krea2").replacingOccurrences(
            of: #""prompt""#,
            with: #""modelVariant": "z-image", "isEditMode": false, "customBaseModel": "x", "sourcePath": "/s.png", "prompt""#
        )
        #expect(try classify("zimage_1.png", json) == [.krea2])
        #expect(try resolve("zimage_1.png", json) == [.krea2])
    }

    /// A sidecar that does not decode as its tagged family is no family: the
    /// tag is trusted, so nothing falls through to the next shape that fits.
    @Test func aSidecarThatFailsItsTaggedFamilyIsNoFamily() throws {
        #expect(try classify("image_1.png", Self.tagged(Self.krea2OrZImage, "flux")).isEmpty)
        #expect(try resolve("image_1.png", Self.tagged(Self.krea2OrZImage, "flux")).isEmpty)
    }

    /// A tag this build does not know comes from a newer build's family. Its
    /// shape says nothing reliable, so it is no family rather than a guess.
    @Test func anUnknownTagIsNoFamily() throws {
        #expect(try classify("renamed.png", Self.tagged(Self.qwen21, "future-model")).isEmpty)
    }

    /// Every family's writer records its tag. Older builds ignore the key: a
    /// synthesized decoder skips keys it does not know.
    @Test func everyFamilyWritesItsTag() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func tag(_ name: String, _ write: (String) -> Void) throws -> String? {
            let path = dir.appendingPathComponent(name).path
            write(path)
            let data = try Data(contentsOf: MetadataSidecar.sidecarURL(for: path))
            return try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["family"] as? String
        }

        #expect(try tag("f.png") { MetadataSidecar.write(GenerationMetadata.from(job: FluxJob(prompt: "f")), for: $0) } == "flux")
        #expect(try tag("i.png") { MetadataSidecar.write(Ideogram4Metadata.from(job: Ideogram4Job(plainPrompt: "i")), for: $0) } ==
            "ideogram4")
        #expect(try tag("k.png") { MetadataSidecar.write(Krea2Metadata.from(job: Krea2Job(prompt: "k")), for: $0) } == "krea2")
        #expect(try tag("z.png") { MetadataSidecar.write(ZImageMetadata.from(job: ZImageJob(prompt: "z")), for: $0) } == "zimage")
        #expect(try tag("q.png") { MetadataSidecar.write(Qwen21Metadata.from(job: Qwen21Job(prompt: "q")), for: $0) } == "qwen21")
        #expect(try tag("s.png") { MetadataSidecar.write(SeedVR2Metadata.from(job: SeedVR2Job(sourcePath: "/s.png")), for: $0) } ==
            "seedvr2")
    }

    /// The writer sets the tag from the sidecar's type, over any value already
    /// on it, so no caller can write a wrong one.
    @Test func theWriterSetsTheTagFromTheType() throws {
        var meta = Krea2Metadata.from(job: Krea2Job(prompt: "k"))
        meta.family = "flux"
        let path = try image("renamed.png", sidecar: nil)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        MetadataSidecar.write(meta, for: path)
        #expect(MetadataSidecar.read(Krea2Metadata.self, for: path)?.family == "krea2")
        #expect(Self.families(AnySidecar.read(forImageAt: path)) == [.krea2])
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
        MetadataSidecar.write(
            GenerationMetadata.from(job: FluxJob(prompt: "f", negativePrompt: "n", loras: [lora])),
            for: path("image_1.png")
        )
        MetadataSidecar.write(Ideogram4Metadata.from(job: Ideogram4Job(plainPrompt: "i")), for: path("ideogram4_1.png"))
        MetadataSidecar.write(Krea2Metadata.from(job: Krea2Job(prompt: "k", negativePrompt: "n")), for: path("krea2_1.png"))
        MetadataSidecar.write(ZImageMetadata.from(job: ZImageJob(modelVariant: .zimage, prompt: "z")), for: path("zimage_1.png"))
        MetadataSidecar.write(Qwen21Metadata.from(job: Qwen21Job(prompt: "q")), for: path("qwen21_1.png"))

        #expect(Self.families(AnySidecar.read(forImageAt: path("image_1.png"))) == [.flux])
        #expect(Self.families(AnySidecar.read(forImageAt: path("ideogram4_1.png"))) == [.ideogram4])
        #expect(Self.families(AnySidecar.read(forImageAt: path("krea2_1.png"))) == [.krea2])
        #expect(Self.families(AnySidecar.read(forImageAt: path("qwen21_1.png"))) == [.qwen21])
        let zimage = AnySidecar.read(forImageAt: path("zimage_1.png"))
        #expect(Self.families(zimage) == [.zimage])
        guard case let .zimage(meta) = zimage else {
            Issue.record("the Z-Image sidecar did not read as Z-Image")
            return
        }
        #expect(meta.resolvedVariant == .zimage)
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
    /// build, or a model since removed) fails the Flux decode. It has every field
    /// Krea 2 requires, but it is still a Flux sidecar: it reads as no family.
    @Test func aFluxSidecarWithAnUnknownModelIsNotClaimedByKrea2() throws {
        let json = Self.flux.replacingOccurrences(of: #""model": "flux2-klein-9b""#, with: #""model": "flux9-ultra""#)
        #expect(try classify("image_1.png", json).isEmpty)
        #expect(try resolve("image_1.png", json).isEmpty)
    }
}
