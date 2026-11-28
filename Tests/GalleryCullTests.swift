import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Which gallery images the full-size viewer pages through and Compare cycles.
struct GalleryCullTests {
    private static func item(_ name: String, board: String = "Default") -> GalleryItem {
        GalleryItem(
            id: UUID(), path: "/out/\(board)/\(name).png", board: board, modifiedAt: Date(timeIntervalSince1970: 0),
            searchHaystack: name
        )
    }

    private let a = item("flux_a")
    private let otherBoard = item("flux_b", board: "Other")
    private let krea = item("krea2_c")
    private let b = item("flux_d")
    private let c = item("flux_e")

    private var items: [GalleryItem] {
        [a, otherBoard, krea, b, c]
    }

    // MARK: - Siblings and paging

    @Test func siblingsShareTheBoardAndTheActiveFamily() {
        #expect(GalleryCull.siblings(of: b, in: items, family: .flux).map(\.id) == [a.id, b.id, c.id])
    }

    @Test func pagingStepsThroughSiblingsAndStopsAtTheEnds() {
        #expect(GalleryCull.step(from: a, by: 1, in: items, family: .flux)?.id == b.id)
        #expect(GalleryCull.step(from: b, by: -1, in: items, family: .flux)?.id == a.id)
        #expect(GalleryCull.step(from: a, by: -1, in: items, family: .flux) == nil)
        #expect(GalleryCull.step(from: c, by: 1, in: items, family: .flux) == nil)
    }

    @Test func theEndsShowWhichArrowsApply() {
        #expect(GalleryCull.edges(of: a, in: items, family: .flux) == (hasPrev: false, hasNext: true))
        #expect(GalleryCull.edges(of: b, in: items, family: .flux) == (hasPrev: true, hasNext: true))
        #expect(GalleryCull.edges(of: c, in: items, family: .flux) == (hasPrev: true, hasNext: false))
        // An image outside the active family is not among the shown images.
        #expect(GalleryCull.edges(of: krea, in: items, family: .flux) == (hasPrev: false, hasNext: false))
    }

    // MARK: - Flags

    @Test func pressingTheSameFlagAgainClearsIt() {
        #expect(GalleryCull.toggled(.pick, pressing: .pick) == nil)
        #expect(GalleryCull.toggled(.pick, pressing: .reject) == .reject)
        #expect(GalleryCull.toggled(nil, pressing: .pick) == .pick)
        #expect(GalleryCull.toggled(.reject, pressing: nil) == nil)
    }

    // MARK: - Compare

    @Test func theCandidateCyclesPastTheSelectAndWraps() {
        let pair = ComparePair(selectId: b.id, candidateId: a.id)
        let siblings = GalleryCull.siblings(of: b, in: items, family: .flux)
        #expect(pair.cyclingCandidate(by: 1, through: siblings)?.candidateId == c.id)
        #expect(pair.cyclingCandidate(by: -1, through: siblings)?.candidateId == c.id)
        let next = pair.cyclingCandidate(by: 1, through: siblings)
        #expect(next?.cyclingCandidate(by: 1, through: siblings)?.candidateId == a.id)
        #expect(next?.selectId == b.id)
    }

    @Test func aSelectWithNoSiblingsCannotCycle() {
        let pair = ComparePair(selectId: a.id, candidateId: a.id)
        #expect(pair.cyclingCandidate(by: 1, through: [a]) == nil)
    }

    @Test func swappingPromotesTheCandidate() {
        let pair = ComparePair(selectId: a.id, candidateId: b.id)
        #expect(pair.swapped == ComparePair(selectId: b.id, candidateId: a.id))
    }
}
