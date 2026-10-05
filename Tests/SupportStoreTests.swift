import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The one-time support nudge (spec §5): after 50 images, unless it was
/// dismissed, the Support window was opened, or a tip was made.
struct SupportStoreTests {
    private func defaults() -> MemorySupportDefaults {
        MemorySupportDefaults()
    }

    @Test func theRuleNeedsTheThresholdAndNothingElse() {
        #expect(SupportNudge.shouldShow(imagesGenerated: 50, threshold: 50, retired: false, tipped: false, windowOpened: false))
        #expect(!SupportNudge.shouldShow(imagesGenerated: 49, threshold: 50, retired: false, tipped: false, windowOpened: false))
        #expect(!SupportNudge.shouldShow(imagesGenerated: 80, threshold: 50, retired: true, tipped: false, windowOpened: false))
        #expect(!SupportNudge.shouldShow(imagesGenerated: 80, threshold: 50, retired: false, tipped: true, windowOpened: false))
        #expect(!SupportNudge.shouldShow(imagesGenerated: 80, threshold: 50, retired: false, tipped: false, windowOpened: true))
    }

    @Test func theNudgeAppearsAtTheThresholdAndRetiresForGood() {
        let d = defaults()
        let store = SupportStore(defaults: d, threshold: 3)
        store.recordImages(2)
        #expect(!store.showsNudge)
        store.recordImages(1)
        #expect(store.showsNudge)

        store.retireNudge()
        #expect(!store.showsNudge)
        #expect(!SupportStore(defaults: d, threshold: 3).showsNudge)
    }

    @Test func openingTheWindowOrTippingKeepsItAway() {
        let opened = SupportStore(defaults: defaults(), threshold: 1)
        opened.noteWindowOpened()
        opened.recordImages(5)
        #expect(!opened.showsNudge)

        let tipped = SupportStore(defaults: defaults(), threshold: 1)
        tipped.noteTipped()
        tipped.recordImages(5)
        #expect(!tipped.showsNudge)
        #expect(tipped.hasTipped)
    }

    @Test func theCountSurvivesARelaunch() {
        let d = defaults()
        SupportStore(defaults: d, threshold: 50).recordImages(7)
        #expect(SupportStore(defaults: d, threshold: 50).imagesGenerated == 7)
    }

    @Test func aDebugThresholdComesFromTheLaunchArguments() {
        let d = defaults()
        #expect(SupportNudge.configuredThreshold(arguments: d) == SupportNudge.defaultThreshold)
        d.set(2, forKey: "supportNudgeThreshold")
        #if DEBUG
            #expect(SupportNudge.configuredThreshold(arguments: d) == 2)
        #else
            #expect(SupportNudge.configuredThreshold(arguments: d) == SupportNudge.defaultThreshold)
        #endif
    }
}
