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
        forms.flux.model = .custom
        forms.flux.customBaseModel = .qwen21Turbo
        #expect(forms.active === forms.qwen21)
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
