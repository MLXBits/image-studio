import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// What Remix and Apply Settings load for an image: its own settings, or an
/// upscale's source settings, filed under the board the image is in now.
@MainActor
struct ReplayTargetTests {
    private func krea2(prompt: String = "a fox", board: String? = nil) -> Krea2Metadata {
        var meta = Krea2Metadata.from(job: Krea2Job(prompt: prompt))
        meta.board = board
        return meta
    }

    private func upscale(sourceZImage: ZImageMetadata? = nil) -> SeedVR2Metadata {
        var meta = SeedVR2Metadata.from(job: SeedVR2Job(sourcePath: ""))
        meta.sourceZImage = sourceZImage
        return meta
    }

    private func item(
        board: String,
        krea2: Krea2Metadata? = nil,
        seedVR2: SeedVR2Metadata? = nil
    ) -> GalleryItem {
        GalleryItem(
            id: UUID(), path: "/out/image.png", board: board, modifiedAt: Date(timeIntervalSince1970: 0),
            krea2Metadata: krea2, seedVR2Metadata: seedVR2, searchHaystack: ""
        )
    }

    private func board(of sidecar: AnySidecar?) -> String? {
        switch sidecar {
        case let .flux(meta): meta.board
        case let .ideogram4(meta): meta.board
        case let .krea2(meta): meta.board
        case let .zimage(meta): meta.board
        case let .qwen21(meta): meta.board
        case let .seedVR2(meta): meta.board
        case nil: nil
        }
    }

    @Test func aGeneratedImageReplaysItsOwnSettings() {
        let target = AnySidecar.krea2(krea2(prompt: "a heron")).replayTarget
        guard case let .krea2(meta) = target else {
            Issue.record("expected Krea 2, got \(String(describing: target))")
            return
        }
        #expect(meta.prompt == "a heron")
    }

    @Test func anUpscaleReplaysTheImageItWasMadeFrom() {
        let source = ZImageMetadata.from(job: ZImageJob(prompt: "a lantern"))
        let target = AnySidecar.seedVR2(upscale(sourceZImage: source)).replayTarget
        guard case let .zimage(meta) = target else {
            Issue.record("expected Z-Image, got \(String(describing: target))")
            return
        }
        #expect(meta.prompt == "a lantern")
    }

    /// Upscales from before the source was folded into their sidecar.
    @Test func anUpscaleWithNoSourceHasNothingToReplay() {
        #expect(AnySidecar.seedVR2(upscale()).replayTarget == nil)
    }

    @Test(arguments: ["Portraits", nil] as [String?])
    func everyFamilyCanBeFiledUnderABoard(_ board: String?) {
        // Each starts on another board, so filing under nil must clear it.
        let sidecars: [AnySidecar] = [
            .flux(GenerationMetadata.from(job: FluxJob()).filed(under: "Old")),
            .ideogram4(Ideogram4Metadata.from(job: Ideogram4Job()).filed(under: "Old")),
            .krea2(krea2(board: "Old")),
            .zimage(ZImageMetadata.from(job: ZImageJob()).filed(under: "Old")),
            .qwen21(Qwen21Metadata.from(job: Qwen21Job()).filed(under: "Old")),
        ]
        for sidecar in sidecars {
            #expect(self.board(of: sidecar) == "Old")
            #expect(self.board(of: sidecar.filed(under: board)) == board)
        }
    }

    /// The sidecar may predate boards, or name one the image was moved out of.
    @Test func aGalleryImageReplaysUnderTheBoardItIsIn() {
        let image = item(board: "Portraits", krea2: krea2(board: "Old"))
        #expect(board(of: image.replaySidecar) == "Portraits")
    }

    /// "Default" is the output folder's root, which a job records as no board.
    @Test func anImageInTheDefaultBoardReplaysWithNoBoard() {
        let image = item(board: "Default", krea2: krea2(board: "Old"))
        #expect(image.replaySidecar != nil)
        #expect(board(of: image.replaySidecar) == nil)
    }

    @Test func anUpscaleInTheGalleryReplaysItsSourceUnderItsOwnBoard() {
        var source = ZImageMetadata.from(job: ZImageJob(prompt: "a lantern"))
        source.board = "Old"
        let image = item(board: "Upscaled", seedVR2: upscale(sourceZImage: source))
        guard case let .zimage(meta) = image.replaySidecar else {
            Issue.record("expected Z-Image, got \(String(describing: image.replaySidecar))")
            return
        }
        #expect(meta.prompt == "a lantern")
        #expect(meta.board == "Upscaled")
    }

    /// An upscale's completed preview replays its source like its gallery item does.
    @Test func anUpscaleSidecarReplaysItsSourceUnderTheUpscalesBoard() {
        var source = ZImageMetadata.from(job: ZImageJob(prompt: "a lantern"))
        source.board = "Old"
        var meta = upscale(sourceZImage: source)
        meta.board = "Upscaled"
        guard case let .zimage(replayed) = meta.replaySidecar else {
            Issue.record("expected Z-Image, got \(String(describing: meta.replaySidecar))")
            return
        }
        #expect(replayed.prompt == "a lantern")
        #expect(replayed.board == "Upscaled")
        #expect(upscale().replaySidecar == nil)
    }

    /// The upscale sheet records a root image's board as "Default", which a job
    /// records as no board, as the gallery item's replay does.
    @Test func anUpscaleOnTheDefaultBoardReplaysWithNoBoard() {
        var meta = upscale(sourceZImage: ZImageMetadata.from(job: ZImageJob()))
        meta.board = "Default"
        #expect(meta.replaySidecar != nil)
        #expect(board(of: meta.replaySidecar) == nil)
    }

    @Test func anImageWithNoSidecarHasNothingToReplay() {
        #expect(item(board: "Default").replaySidecar == nil)
    }
}
