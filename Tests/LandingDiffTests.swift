@testable import MLXBits_Image_Studio
import Testing

/// The one landing handler compares every queue's landing before and after a
/// change: any change rescans the gallery, and only the first image of a run
/// is selected.
@Suite("Landing diff")
struct LandingDiffTests {
    private func landing(seq: Int, run: Int, first: String) -> Landing {
        Landing(seq: seq, run: run, firstPath: first)
    }

    @Test func nothingChangedIsNoLanding() {
        let landings = [landing(seq: 1, run: 1, first: "/a.png"), nil]
        let outcome = LandingDiff.compare(old: landings, new: landings)
        #expect(outcome == LandingDiff.Outcome(landed: false, selectPath: nil))
    }

    @Test func aRunsFirstLandingSelectsItsImage() {
        let outcome = LandingDiff.compare(
            old: [nil, nil],
            new: [nil, landing(seq: 1, run: 1, first: "/a.png")]
        )
        #expect(outcome == LandingDiff.Outcome(landed: true, selectPath: "/a.png"))
    }

    @Test func aLaterLandingOfTheSameRunDoesNotMoveTheSelection() {
        let outcome = LandingDiff.compare(
            old: [landing(seq: 1, run: 1, first: "/a.png")],
            new: [landing(seq: 2, run: 1, first: "/a.png")]
        )
        #expect(outcome == LandingDiff.Outcome(landed: true, selectPath: nil))
    }

    @Test func theNextRunOnTheSameQueueSelectsAgain() {
        let outcome = LandingDiff.compare(
            old: [landing(seq: 3, run: 1, first: "/a.png")],
            new: [landing(seq: 4, run: 2, first: "/b.png")]
        )
        #expect(outcome == LandingDiff.Outcome(landed: true, selectPath: "/b.png"))
    }

    /// Only `seq` tells two landings of one run apart. The old observer read a
    /// batch's image count, so an equal count in a row never fired.
    @Test func aLandingWhereOnlyTheCountChangedStillLands() {
        let outcome = LandingDiff.compare(
            old: [landing(seq: 4, run: 2, first: "/a.png")],
            new: [landing(seq: 5, run: 2, first: "/a.png")]
        )
        #expect(outcome.landed)
    }

    @Test func twoQueuesChangingTogetherSelectTheOneThatStartedARun() {
        let outcome = LandingDiff.compare(
            old: [landing(seq: 1, run: 1, first: "/a.png"), nil],
            new: [landing(seq: 2, run: 1, first: "/a.png"), landing(seq: 1, run: 1, first: "/x.png")]
        )
        #expect(outcome == LandingDiff.Outcome(landed: true, selectPath: "/x.png"))
    }
}
