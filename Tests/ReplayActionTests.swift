import Foundation
@testable import MLXBits_Image_Studio
import SwiftUI
import Testing

/// A replay moves the model picker to the family (and checkpoint) the image was
/// made with, arms the picker handlers that move fires, and loads the settings
/// into that family's form. Remix rolls a new seed; Apply Settings keeps it.
@MainActor
struct ReplayActionTests {
    private final class Armed {
        var observers: Set<ModelChangeObserver> = []
    }

    private let forms = FamilyForms()
    private let armed = Armed()

    private var params: ParamsPanelState {
        forms.flux
    }

    private var ideogramParams: Ideogram4ParamsPanelState {
        forms.ideogram4
    }

    private var krea2Params: Krea2ParamsPanelState {
        forms.krea2
    }

    private var zimageParams: ZImageParamsPanelState {
        forms.zimage
    }

    private var qwen21Params: Qwen21ParamsPanelState {
        forms.qwen21
    }

    private var replay: ReplayAction {
        let armed = armed
        return ReplayAction(
            forms: forms,
            suppressedModelObservers: Binding(get: { armed.observers }, set: { armed.observers = $0 })
        )
    }

    private func krea2(seed: Int) -> AnySidecar {
        var meta = Krea2Metadata.from(job: Krea2Job(prompt: "a fox"))
        meta.seed = seed
        return .krea2(meta)
    }

    @Test func applySettingsKeepsTheRecordedSeed() {
        replay(krea2(seed: 42), mode: .applySettings)
        #expect(krea2Params.seed == 42)
        #expect(krea2Params.prompt == "a fox")
    }

    @Test func remixRollsANewSeed() {
        replay(krea2(seed: 42), mode: .remix)
        #expect(krea2Params.seed == -1)
        #expect(krea2Params.prompt == "a fox")
    }

    /// Without the guard, the picker's handler would reset the form just written.
    @Test func replayMovesThePickerAndArmsItsHandler() {
        params.model = .flux2Klein9B
        replay(krea2(seed: 1), mode: .applySettings)
        #expect(params.model == .krea2)
        #expect(armed.observers == [.model])
    }

    /// A handler that is armed but never fires would swallow the user's next switch.
    @Test func replayOnTheSameModelArmsNothing() {
        params.model = .krea2
        replay(krea2(seed: 1), mode: .applySettings)
        #expect(armed.observers.isEmpty)
    }

    @Test func anImageFromACustomCheckpointReplaysAsThatCheckpoint() {
        let meta = ZImageMetadata.from(job: ZImageJob(modelVariant: .zimage, customModelRepo: "me/zimage-ft"))
        replay(.zimage(meta), mode: .applySettings)
        #expect(params.model == .custom)
        #expect(params.customModelRepo == "me/zimage-ft")
        #expect(params.customBaseModel == .zimage)
        #expect(armed.observers == [.model, .customBase])
    }

    @Test func zImageReplaysTheVariantItWasMadeWith() {
        let meta = ZImageMetadata.from(job: ZImageJob(modelVariant: .zimageTurbo))
        params.model = .zimage
        replay(.zimage(meta), mode: .applySettings)
        #expect(params.model == .zimageTurbo)
    }

    /// Sidecars record a stock model's checkpoint as an empty string, or omit it.
    @Test func anEmptyCheckpointReplaysAsTheStockModel() {
        var meta = Krea2Metadata.from(job: Krea2Job())
        meta.customModelRepo = ""
        replay(.krea2(meta), mode: .applySettings)
        #expect(params.model == .krea2)
        #expect(!armed.observers.contains(.customBase))
    }

    @Test(arguments: [ReplayMode.remix, .applySettings])
    func everyFamilyRollsOrKeepsTheSeed(_ mode: ReplayMode) {
        var flux = GenerationMetadata.from(job: FluxJob())
        flux.seed = 42
        var ideogram = Ideogram4Metadata.from(job: Ideogram4Job())
        ideogram.seed = 42
        var zimage = ZImageMetadata.from(job: ZImageJob())
        zimage.seed = 42
        var qwen = Qwen21Metadata.from(job: Qwen21Job())
        qwen.seed = 42
        let replayed: [(AnySidecar, () -> Int)] = [
            (.flux(flux), { params.seed }),
            (.ideogram4(ideogram), { ideogramParams.seed }),
            (krea2(seed: 42), { krea2Params.seed }),
            (.zimage(zimage), { zimageParams.seed }),
            (.qwen21(qwen), { qwen21Params.seed }),
        ]
        for (sidecar, seed) in replayed {
            replay(sidecar, mode: mode)
            #expect(seed() == (mode == .remix ? -1 : 42))
        }
    }

    /// The caller presses Generate after a Remix only when this returns true.
    @Test func anUpscaleWithNoSourceReplaysNothing() {
        let upscale = SeedVR2Metadata.from(job: SeedVR2Job(sourcePath: ""))
        params.model = .flux2Klein9B
        #expect(!replay(.seedVR2(upscale), mode: .remix))
        #expect(params.model == .flux2Klein9B)
        #expect(replay(krea2(seed: 1), mode: .remix))
    }

    @Test func aFluxReplayMovesThePickerToItsModel() {
        let meta = GenerationMetadata.from(job: FluxJob(model: .flux2Klein4B, prompt: "a cat"))
        replay(.flux(meta), mode: .applySettings)
        #expect(params.model == .flux2Klein4B)
        #expect(params.prompt == "a cat")
        #expect(armed.observers == [.model])
    }

    @Test func anIdeogramReplayMovesThePickerToIdeogram() {
        var meta = Ideogram4Metadata.from(job: Ideogram4Job())
        meta.seed = 7
        replay(.ideogram4(meta), mode: .applySettings)
        #expect(params.model == .ideogram4)
        #expect(ideogramParams.seed == 7)
    }

    @Test func anUpscaleReplaysTheImageItWasMadeFrom() {
        var upscale = SeedVR2Metadata.from(job: SeedVR2Job(sourcePath: ""))
        upscale.sourceQwen21 = Qwen21Metadata.from(job: Qwen21Job(prompt: "a bird"))
        replay(.seedVR2(upscale), mode: .applySettings)
        #expect(params.model == .qwen21Turbo)
        #expect(qwen21Params.prompt == "a bird")
    }
}
