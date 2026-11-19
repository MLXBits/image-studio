@testable import MLXBits_Image_Studio
import Testing

@Suite("Background signals")
struct BackgroundSignalsTests {
    @Test func aCompletedJobCountsItsImages() {
        let one = BackgroundSignals.content(for: JobFinish(family: .krea2, outcome: .completed(images: 1)))
        #expect(one.title == "Krea 2 finished")
        #expect(one.body == "1 image saved.")
        let many = BackgroundSignals.content(for: JobFinish(family: .flux, outcome: .completed(images: 4)))
        #expect(many.body == "4 images saved.")
        let none = BackgroundSignals.content(for: JobFinish(family: .flux, outcome: .completed(images: 0)))
        #expect(none.body == "The job finished.")
    }

    @Test func aFailedJobShowsItsSummary() {
        let text = BackgroundSignals.content(
            for: JobFinish(family: .qwen21, outcome: .failed(summary: "ValueError: bad size"))
        )
        #expect(text.title == "Qwen Image 2.1 failed")
        #expect(text.body == "ValueError: bad size")
    }

    @Test func anEmptyQueueHasNoBadge() {
        #expect(BackgroundSignals.badgeLabel(queued: 0) == nil)
        #expect(BackgroundSignals.badgeLabel(queued: 3) == "3")
    }
}

@Suite("Model family shortcuts")
struct ModelFamilyVariantToSelectTests {
    @Test func prefersTheModelLastPickedInTheFamily() {
        let variant = ModelFamily.zimage.variantToSelect(remembered: [.zimage: .zimage], defaultModel: .flux2Klein4B)
        #expect(variant == .zimage)
    }

    @Test func fallsBackToTheSettingsDefaultInTheSameFamily() {
        #expect(ModelFamily.flux.variantToSelect(remembered: [:], defaultModel: .flux3Klein) == .flux3Klein)
    }

    @Test func aDefaultFromAnotherFamilyIsIgnored() {
        #expect(ModelFamily.flux.variantToSelect(remembered: [:], defaultModel: .krea2) == .flux2Klein9B)
        #expect(ModelFamily.zimage.variantToSelect(remembered: [:], defaultModel: .flux3Klein) == .zimageTurbo)
    }

    @Test func aCustomCheckpointIsNeverSelected() {
        let variant = ModelFamily.flux.variantToSelect(remembered: [.flux: .custom], defaultModel: .custom)
        #expect(variant == .flux2Klein9B)
    }

    @Test func everyGenerativeFamilyHasAModelAndTheUpscalerHasNone() {
        for family in ModelFamily.generative {
            #expect(family.variantToSelect(remembered: [:], defaultModel: .custom)?.family == family)
        }
        #expect(ModelFamily.seedvr2.variantToSelect(remembered: [:], defaultModel: .flux2Klein9B) == nil)
    }
}
