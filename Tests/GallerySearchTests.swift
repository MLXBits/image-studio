import Foundation
@testable import MLXBits_Image_Studio
import Testing

final class GallerySearchTests {
    private static let t0 = Date(timeIntervalSince1970: 0)

    // MARK: - Builders

    private func fluxItem(
        path: String, board: String, metadata: GenerationMetadata? = nil,
        flag: PickFlag? = nil, rating: Int = 0
    ) -> GalleryItem {
        GalleryItem(
            id: UUID(), path: path, board: board, modifiedAt: Self.t0,
            thumbnailData: nil, thumbnailImage: nil, metadata: metadata,
            ideogram4Metadata: nil, krea2Metadata: nil, zimageMetadata: nil,
            seedVR2Metadata: nil, flag: flag, rating: rating
        )
    }

    private func item(
        path: String, board: String, ideogram4Metadata: Ideogram4Metadata? = nil,
        krea2Metadata: Krea2Metadata? = nil, zimageMetadata: ZImageMetadata? = nil,
        seedVR2Metadata: SeedVR2Metadata? = nil, flag: PickFlag? = nil, rating: Int = 0
    ) -> GalleryItem {
        GalleryItem(
            id: UUID(), path: path, board: board, modifiedAt: Self.t0,
            thumbnailData: nil, thumbnailImage: nil, metadata: nil,
            ideogram4Metadata: ideogram4Metadata, krea2Metadata: krea2Metadata,
            zimageMetadata: zimageMetadata, seedVR2Metadata: seedVR2Metadata,
            flag: flag, rating: rating
        )
    }

    private func fluxMetadata(
        prompt: String, negativePrompt: String = "", seed: Int = 0,
        loras: [LoraEntry] = []
    ) -> GenerationMetadata {
        GenerationMetadata(
            prompt: prompt, negativePrompt: negativePrompt,
            model: .flux2Klein9B, customModelRepo: "",
            customBaseModel: .flux2KleinBase9B, seed: seed, steps: 20,
            guidance: 3.5, width: 1024, height: 1024, quantize: 8,
            lowRam: false, imagePath: "", imageStrength: 0,
            editImagePaths: nil, loras: loras, board: nil,
            pidDecode: nil, pidDegradeSigma: nil,
            generatedAt: Self.t0, startedAt: nil, log: nil
        )
    }

    private func ideogram4Metadata(
        plainPrompt: String, seed: Int = 0, loras: [LoraEntry] = []
    ) -> Ideogram4Metadata {
        Ideogram4Metadata(
            customModelRepo: nil, caption: .empty(), usePlainPrompt: true,
            plainPrompt: plainPrompt, preset: .turbo, seed: seed,
            width: 1024, height: 1024, quantize: 8, lowRam: false,
            loras: loras, board: nil, pidDecode: nil, pidDegradeSigma: nil,
            generatedAt: Self.t0, startedAt: nil, log: nil
        )
    }

    private func krea2Metadata(
        prompt: String, seed: Int = 0, loras: [LoraEntry] = []
    ) -> Krea2Metadata {
        Krea2Metadata(
            customModelRepo: nil, prompt: prompt, negativePrompt: nil,
            seed: seed, steps: 20, guidance: 1.0, width: 1024, height: 1024,
            quantize: 8, lowRam: nil, loras: loras, imagePath: nil,
            imageStrength: nil, board: nil, pidDecode: nil,
            pidDegradeSigma: nil, generatedAt: Self.t0, startedAt: nil,
            log: nil
        )
    }

    private func zimageMetadata(
        prompt: String, seed: Int = 0, loras: [LoraEntry] = []
    ) -> ZImageMetadata {
        ZImageMetadata(
            modelVariant: nil, customModelRepo: nil, prompt: prompt,
            negativePrompt: nil, seed: seed, steps: 20, guidance: 1.0,
            width: 1024, height: 1024, quantize: 4, loras: loras,
            imagePath: nil, imageStrength: nil, board: nil, pidDecode: nil,
            pidDegradeSigma: nil, generatedAt: Self.t0, startedAt: nil,
            log: nil
        )
    }

    private func seedVR2Metadata(sourcePath: String) -> SeedVR2Metadata {
        SeedVR2Metadata(
            sourcePath: sourcePath, model: "seedvr2-7b", scale: 2,
            softness: 0, quantize: 8, seed: 0, width: 1024, height: 1024,
            board: nil, generatedAt: Self.t0, startedAt: nil, log: nil,
            sourceFlux: nil, sourceIdeogram4: nil, sourceKrea2: nil,
            sourceZImage: nil
        )
    }

    // MARK: - haystack(for:)

    @Test func theHaystackCoversPromptNegativeSeedModelAndLoras() {
        let item = fluxItem(
            path: "/out/a-portrait.png", board: "Default",
            metadata: fluxMetadata(
                prompt: "A calm PORTRAIT",
                negativePrompt: "Blurry, extra fingers",
                seed: 42,
                loras: [LoraEntry(path: "/loras/style.safetensors")]
            )
        )
        // `"\(meta.model)"` stringifies the enum's case name (flux2Klein9B), not
        // its rawValue — pinned verbatim from the view's current searchHaystack.
        #expect(
            GallerySearch.haystack(for: item)
                == "a-portrait.png a calm portrait blurry, extra fingers 42 flux2klein9b style.safetensors"
        )
    }

    @Test func anItemWithoutMetadataHasAFilenameOnlyHaystack() {
        let item = fluxItem(path: "/out/plain.png", board: "Default")
        #expect(GallerySearch.haystack(for: item) == "plain.png")
    }

    @Test func theHaystackCoversTheIdeogramKrea2AndZImageFamilies() {
        let ideogram = item(
            path: "/out/ideogram4_poster.png", board: "Default",
            ideogram4Metadata: ideogram4Metadata(
                plainPrompt: "Bold POSTER", seed: 7,
                loras: [LoraEntry(path: "/loras/poster.safetensors")]
            )
        )
        #expect(
            GallerySearch.haystack(for: ideogram)
                == "ideogram4_poster.png bold poster 7 poster.safetensors"
        )

        let krea2 = item(
            path: "/out/krea2_render.png", board: "Default",
            krea2Metadata: krea2Metadata(
                prompt: "Cinematic RENDER", seed: 99,
                loras: [LoraEntry(path: "/loras/cine.safetensors")]
            )
        )
        #expect(
            GallerySearch.haystack(for: krea2)
                == "krea2_render.png cinematic render 99 cine.safetensors"
        )

        let zimage = item(
            path: "/out/zimage_photo.png", board: "Default",
            zimageMetadata: zimageMetadata(
                prompt: "Soft PHOTO", seed: 5,
                loras: [LoraEntry(path: "/loras/soft.safetensors")]
            )
        )
        #expect(
            GallerySearch.haystack(for: zimage)
                == "zimage_photo.png soft photo 5 soft.safetensors"
        )
    }

    @Test func seedVR2MetadataDoesNotEnterTheHaystack() {
        let item = item(
            path: "/out/seedvr2_up.png", board: "Default",
            seedVR2Metadata: seedVR2Metadata(sourcePath: "/out/flux_src.png")
        )
        #expect(GallerySearch.haystack(for: item) == "seedvr2_up.png")
    }

    // MARK: - filter(_:family:query:flag:minRating:)

    @Test func filterKeepsOnlyTheRequestedFamily() {
        let items = [
            fluxItem(path: "/out/plain.png", board: "Default"),
            fluxItem(path: "/out/ideogram4_x.png", board: "Default"),
            fluxItem(path: "/out/krea2_y.png", board: "Default"),
            fluxItem(path: "/out/zimage_z.png", board: "Default"),
        ]
        let filtered = GallerySearch.filter(items, family: .krea2, query: "", flag: .all, minRating: 0)
        #expect(filtered.map(\.path) == ["/out/krea2_y.png"])
    }

    @Test func filterHonorsTheFlagFilter() {
        let pick = fluxItem(path: "/out/p.png", board: "Default", flag: .pick)
        let reject = fluxItem(path: "/out/r.png", board: "Default", flag: .reject)
        let unflagged = fluxItem(path: "/out/u.png", board: "Default")
        let items = [pick, reject, unflagged]

        let all = GallerySearch.filter(items, family: .flux, query: "", flag: .all, minRating: 0)
        #expect(all.map(\.path) == ["/out/p.png", "/out/r.png", "/out/u.png"])

        let picks = GallerySearch.filter(items, family: .flux, query: "", flag: .picks, minRating: 0)
        #expect(picks.map(\.path) == ["/out/p.png"])

        let rejects = GallerySearch.filter(items, family: .flux, query: "", flag: .rejects, minRating: 0)
        #expect(rejects.map(\.path) == ["/out/r.png"])

        let unflaggedOnly = GallerySearch.filter(items, family: .flux, query: "", flag: .unflagged, minRating: 0)
        #expect(unflaggedOnly.map(\.path) == ["/out/u.png"])
    }

    @Test func filterHonorsTheMinimumRating() {
        let items = [
            fluxItem(path: "/out/zero.png", board: "Default", rating: 0),
            fluxItem(path: "/out/two.png", board: "Default", rating: 2),
            fluxItem(path: "/out/three.png", board: "Default", rating: 3),
            fluxItem(path: "/out/five.png", board: "Default", rating: 5),
        ]
        let filtered = GallerySearch.filter(items, family: .flux, query: "", flag: .all, minRating: 3)
        #expect(filtered.map(\.path) == ["/out/three.png", "/out/five.png"])
    }

    @Test func theQueryMatchesCaseInsensitivelyAcrossPromptLoraAndSeed() {
        let foo = fluxItem(
            path: "/out/foo.png", board: "Default",
            metadata: fluxMetadata(prompt: "a foo prompt", seed: 7)
        )
        let seeded = fluxItem(
            path: "/out/bar.png", board: "Default",
            metadata: fluxMetadata(prompt: "just bar", seed: 42)
        )
        let items = [foo, seeded]

        let byQuery = GallerySearch.filter(items, family: .flux, query: "  FoO ", flag: .all, minRating: 0)
        #expect(byQuery.map(\.path) == ["/out/foo.png"])

        let bySeed = GallerySearch.filter(items, family: .flux, query: "42", flag: .all, minRating: 0)
        #expect(bySeed.map(\.path) == ["/out/bar.png"])
    }

    // MARK: - sections(_:boards:collapsed:)

    @Test func sectionsOrderDefaultFirstThenSortedBoardsAndKeepEncounterOrder() {
        let items = [
            fluxItem(path: "/out/d.png", board: "Default"),
            fluxItem(path: "/out/a1.png", board: "A"),
            fluxItem(path: "/out/b2.png", board: "B"),
            fluxItem(path: "/out/b1.png", board: "B"),
        ]
        let sections = GallerySearch.sections(items, boards: ["Default", "B", "A"], collapsed: [])
        #expect(sections.map(\.board) == ["Default", "A", "B"])
        #expect(sections[2].items.map(\.path) == ["/out/b2.png", "/out/b1.png"])
    }

    @Test func collapsedBoardsComeBackUnexpanded() {
        let items = [
            fluxItem(path: "/out/a.png", board: "A"),
            fluxItem(path: "/out/b.png", board: "B"),
        ]
        let sections = GallerySearch.sections(items, boards: ["A", "B"], collapsed: ["A"])
        #expect(sections[0].board == "A")
        #expect(sections[0].isExpanded == false)
        #expect(sections[1].board == "B")
        #expect(sections[1].isExpanded == true)
    }

    @Test func aNamedBoardWithNoFilteredItemsStillGetsAnEmptySection() {
        let item = fluxItem(path: "/out/plain.png", board: "Default")
        let filtered = GallerySearch.filter(
            [item], family: .flux, query: "", flag: .picks, minRating: 0
        )
        let sections = GallerySearch.sections(filtered, boards: ["Solo"], collapsed: [])
        #expect(sections.map(\.board) == ["Solo"])
        #expect(sections[0].items.isEmpty)
        #expect(sections[0].isExpanded)
    }

    // MARK: - orderedBoards(for:boards:)

    @Test func orderedBoardsListsDefaultOnlyWhenPresent() {
        let withDefault = [
            fluxItem(path: "/out/d.png", board: "Default"),
            fluxItem(path: "/out/a.png", board: "A"),
            fluxItem(path: "/out/b.png", board: "B"),
        ]
        #expect(GallerySearch.orderedBoards(for: withDefault, boards: ["A", "B"]) == ["Default", "A", "B"])

        let namedOnly = [
            fluxItem(path: "/out/a.png", board: "A"),
            fluxItem(path: "/out/b.png", board: "B"),
        ]
        #expect(GallerySearch.orderedBoards(for: namedOnly, boards: ["A", "B"]) == ["A", "B"])
    }
}
