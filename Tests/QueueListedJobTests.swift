import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Every family's queue runs on the shared ``QueueListedJob`` operations and
/// drawer: each row names its job, and a re-queued job starts from its own
/// family's step count.
@Suite("Shared queue")
struct QueueListedJobTests {
    // MARK: - Row titles

    @Test func aPromptedJobIsTitledByItsPrompt() {
        #expect(FluxJob(prompt: "a cat").queueTitle == "a cat")
        #expect(Krea2Job(prompt: "a heron").queueTitle == "a heron")
        #expect(ZImageJob(prompt: "a fox").queueTitle == "a fox")
        #expect(Qwen21Job(prompt: "a tram").queueTitle == "a tram")
    }

    @Test func anIdeogramJobIsTitledByThePromptItUses() {
        var caption = IdeogramCaption.empty()
        caption.highLevelDescription = "a lighthouse"
        let job = Ideogram4Job(caption: caption, usePlainPrompt: false, plainPrompt: "plain")
        #expect(job.queueTitle == "a lighthouse")

        job.usePlainPrompt = true
        #expect(job.queueTitle == "plain")
    }

    @Test func anUpscaleIsTitledByItsSourceFile() {
        #expect(SeedVR2Job(sourcePath: "/out/2026/cat_1.png").queueTitle == "cat_1.png")
        #expect(SeedVR2Job(sourcePath: "").queueTitle == "(upscale)")
    }

    @Test func anEmptyPromptHasAPlaceholderTitle() {
        #expect(FluxJob(prompt: "").queueRowTitle == "(empty prompt)")
        #expect(Ideogram4Job().queueRowTitle == "(empty prompt)")
    }

    // MARK: - Restart

    private func finish(_ job: some GeneratedJob) {
        job.status = .failed("boom")
        job.currentStep = 3
        job.totalSteps = 99
    }

    @Test func aRestartedJobStartsFromItsFamilysStepCount() {
        let flux = FluxJob(steps: 6)
        let fluxStore = JobStore()
        fluxStore.jobs = [flux]
        finish(flux)
        fluxStore.restart(flux)
        #expect(flux.status == .pending && flux.currentStep == 0 && flux.totalSteps == 6)

        let ideogram = Ideogram4Job(preset: .turbo)
        let ideogramStore = Ideogram4JobStore()
        ideogramStore.jobs = [ideogram]
        finish(ideogram)
        ideogramStore.restart(ideogram)
        #expect(ideogram.totalSteps == Ideogram4Preset.turbo.stepCount)

        let upscale = SeedVR2Job(sourcePath: "/s.png")
        let upscaleStore = SeedVR2JobStore()
        upscaleStore.jobs = [upscale]
        finish(upscale)
        upscaleStore.restart(upscale)
        #expect(upscale.status == .pending && upscale.totalSteps == 0)
    }

    // MARK: - Preview selection

    @Test func thePreviewedJobIsTheActiveJobOfAnyFamily() {
        let krea = Krea2Job()
        let upscale = SeedVR2Job(sourcePath: "/s.png")
        #expect(PreviewState.activeKrea2Job(krea).previewedJob === krea)
        #expect(PreviewState.activeSeedVR2Job(upscale).previewedJob === upscale)
        #expect(PreviewState.idle.previewedJob == nil)
    }
}
