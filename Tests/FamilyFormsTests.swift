import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The window reads the active family's seed, board, precision and readiness
/// through one lookup, so none of those reads can miss a family.
@MainActor
struct FamilyFormsTests {
    private let forms = FamilyForms()

    @Test func eachPickerFamilyHasItsOwnForm() {
        #expect(forms.form(for: .flux) === forms.flux)
        #expect(forms.form(for: .ideogram4) === forms.ideogram4)
        #expect(forms.form(for: .krea2) === forms.krea2)
        #expect(forms.form(for: .zimage) === forms.zimage)
        #expect(forms.form(for: .qwen21) === forms.qwen21)
    }

    /// SeedVR2 is an upscale action, never the picked family, so it has no form.
    @Test func seedVR2HasNoForm() {
        #expect(forms.form(for: .seedvr2) == nil)
    }

    @Test func allIsEveryGenerativeFamilysFormInOrder() {
        let expected = ModelFamily.generative.compactMap { forms.form(for: $0) }
        #expect(expected.count == ModelFamily.generative.count)
        #expect(forms.all.map { ObjectIdentifier($0) } == expected.map { ObjectIdentifier($0) })
    }

    /// A custom checkpoint generates with the form of the family it loads as.
    @Test func theActiveFormFollowsTheFluxPicker() {
        #expect(forms.active === forms.flux)
        forms.flux.model = .krea2
        #expect(forms.active === forms.krea2)
        forms.flux.model = .zimage
        #expect(forms.active === forms.zimage)
        forms.flux.model = .custom
        forms.flux.customBaseModel = .qwen21Turbo
        #expect(forms.active === forms.qwen21)
        forms.flux.customBaseModel = .flux3Klein
        #expect(forms.active === forms.flux)
    }

    /// The panel and the runner both ask what a custom checkpoint loads as:
    /// a custom FLUX 3 has no img2img, so its panel must not offer one.
    @Test func aCustomCheckpointLoadsAsItsTarget() {
        forms.flux.model = .flux2Klein4B
        #expect(forms.flux.loadsAs == .flux2Klein4B)
        forms.flux.model = .custom
        forms.flux.customBaseModel = .flux3Klein
        #expect(forms.flux.loadsAs == .flux3Klein)
    }

    /// FLUX 3 has no img2img, so its panel hides the image: one kept would stay
    /// locked in the gallery with no way to clear it.
    @Test func flux3DropsItsImg2ImgImage() {
        forms.flux.imagePath = "/out/a.png"
        forms.flux.model = .custom
        forms.flux.customBaseModel = .flux2Klein9B
        forms.flux.dropUnusableImg2ImgSource()
        #expect(forms.flux.imagePath == "/out/a.png")
        forms.flux.customBaseModel = .flux3Klein
        forms.flux.dropUnusableImg2ImgSource()
        #expect(forms.flux.imagePath.isEmpty)
    }

    /// A replay restores the recorded image, which a custom FLUX 3 can't use.
    /// Sidecars from before the panel hid it can carry one.
    @Test func replayingACustomFlux3DropsItsImg2ImgImage() {
        let job = FluxJob(model: .custom, customBaseModel: .flux3Klein, prompt: "a fox", imagePath: "/out/a.png")
        forms.flux.apply(metadata: GenerationMetadata.from(job: job), newSeed: false)
        #expect(forms.flux.imagePath.isEmpty)
        let flux2 = FluxJob(model: .flux2Klein9B, prompt: "a fox", imagePath: "/out/a.png")
        forms.flux.apply(metadata: GenerationMetadata.from(job: flux2), newSeed: false)
        #expect(forms.flux.imagePath == "/out/a.png")
    }

    /// The panel offers a negative prompt and guidance only where the runner sends them.
    @Test func aCustomFlux3TakesNoNegativePromptOrGuidance() {
        forms.flux.model = .custom
        forms.flux.customBaseModel = .flux2KleinBase9B
        #expect(forms.flux.sendsNegativePrompt)
        #expect(forms.flux.takesGuidance)
        forms.flux.customBaseModel = .flux3Klein
        #expect(!forms.flux.sendsNegativePrompt)
        #expect(!forms.flux.takesGuidance)
    }

    @Test func flux3BaseTakesGuidanceButNoNegativePrompt() {
        forms.flux.model = .flux3KleinBase
        #expect(forms.flux.takesGuidance)
        #expect(!forms.flux.sendsNegativePrompt)
        forms.flux.model = .flux2Klein9B
        #expect(!forms.flux.takesGuidance)
    }

    /// The gallery refuses to delete an image a form holds as a source.
    @Test func lockedSourcePathsAreEveryFormsSourceImages() {
        forms.flux.imagePath = "/out/flux.png"
        forms.flux.editImagePaths = ["/out/ref.png"]
        forms.krea2.imagePath = "/out/krea.png"
        forms.zimage.imagePath = "/out/z.png"
        #expect(forms.lockedSourcePaths == ["/out/flux.png", "/out/ref.png", "/out/krea.png", "/out/z.png"])
    }

    /// Qwen keeps its references while in Generate mode, but only Edit mode uses them.
    @Test func qwenLocksItsReferencesOnlyInEditMode() {
        forms.qwen21.editImagePaths = ["/out/q.png"]
        #expect(forms.lockedSourcePaths.isEmpty)
        forms.qwen21.isEditMode = true
        #expect(forms.lockedSourcePaths == ["/out/q.png"])
    }

    /// A library edit gives each family its own defaults; Flux keeps its stack.
    @Test func eachFormFollowsTheLibrarysDefaults() {
        let mine = LoraEntry(path: "/loras/mine.safetensors", modelFamily: .flux)
        forms.flux.loras = [mine]
        let library: [LoraEntry] = [
            LoraEntry(path: "/loras/f.safetensors", modelFamily: .flux),
            LoraEntry(path: "/loras/i.safetensors", modelFamily: .ideogram4),
            LoraEntry(path: "/loras/k.safetensors", modelFamily: .krea2),
            LoraEntry(path: "/loras/z.safetensors", modelFamily: .zimage),
            LoraEntry(path: "/loras/q.safetensors", modelFamily: .qwen21),
        ]
        forms.followLibraryDefaults(from: [], to: library)
        #expect(forms.flux.loras.map(\.path) == ["/loras/mine.safetensors", "/loras/f.safetensors"])
        #expect(forms.ideogram4.loras.map(\.path) == ["/loras/i.safetensors"])
        #expect(forms.krea2.loras.map(\.path) == ["/loras/k.safetensors"])
        #expect(forms.zimage.loras.map(\.path) == ["/loras/z.safetensors"])
        #expect(forms.qwen21.loras.map(\.path) == ["/loras/q.safetensors"])
    }

    /// The Fixed Seed pill's clear frees every family, not only the active one.
    @Test func clearingTheFixedSeedFreesEveryForm() {
        for form in forms.all {
            form.seed = 7
        }
        forms.clearFixedSeeds()
        #expect(forms.all.allSatisfy { $0.seed == -1 })
    }

    @Test func fluxNeedsAPrompt() {
        #expect(!forms.flux.canGenerate)
        forms.flux.prompt = "  "
        #expect(!forms.flux.canGenerate)
        forms.flux.prompt = "a fox"
        #expect(forms.flux.canGenerate)
    }

    @Test func fluxEditModeNeedsAReference() {
        forms.flux.prompt = "a fox"
        forms.flux.isEditMode = true
        #expect(!forms.flux.canGenerate)
        forms.flux.editImagePaths = ["/out/a.png"]
        #expect(forms.flux.canGenerate)
    }
}
