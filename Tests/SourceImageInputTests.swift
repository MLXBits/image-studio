@testable import MLXBits_Image_Studio
import Testing

/// A gallery image picked as a source goes to the active model's input, so the
/// active model, not the image's, decides whether the item shows and what it says.
struct SourceImageInputTests {
    private func input(_ variant: FluxModelVariant, editMode: Bool = false) -> SourceImageInput? {
        SourceImageInput.forActive(ModelSelection(variant: variant, quantize: 8), fluxEditMode: editMode)
    }

    private func custom(loadingAs variant: FluxModelVariant, editMode: Bool = false) -> SourceImageInput? {
        let tune = ModelSelection(variant: variant, quantize: 8, customRepo: "org/tune")
        return SourceImageInput.forActive(tune, fluxEditMode: editMode)
    }

    @Test(arguments: [
        FluxModelVariant.flux2Klein4B, .flux2Klein9B, .flux2KleinBase4B, .flux2KleinBase9B, .krea2, .zimage, .zimageTurbo,
    ])
    func img2imgModelsTakeAnImg2ImgSource(_ variant: FluxModelVariant) {
        #expect(input(variant) == .img2img)
    }

    /// FLUX.2 has both inputs: its edit mode takes references, not an img2img image.
    @Test func flux2EditModeTakesAnEditReference() {
        #expect(input(.flux2Klein4B, editMode: true) == .editReference)
    }

    /// The edit-mode switch is Flux's alone.
    @Test(arguments: [FluxModelVariant.krea2, .zimage])
    func otherModelsIgnoreFluxEditMode(_ variant: FluxModelVariant) {
        #expect(input(variant, editMode: true) == .img2img)
    }

    /// FLUX 3 has no img2img mode, so in either mode the image becomes an edit
    /// reference, as it does for Qwen; using it turns Edit mode on.
    @Test(arguments: [FluxModelVariant.flux3Klein, .flux3KleinBase], [false, true])
    func flux3TakesAnEditReferenceInEitherMode(_ variant: FluxModelVariant, editMode: Bool) {
        #expect(input(variant, editMode: editMode) == .editReference)
    }

    /// A custom checkpoint's form has no Generate/Edit switch, so the item must
    /// not turn on an Edit mode it cannot leave. It still follows the model it
    /// loads as.
    @Test func aCustomCheckpointNeverTurnsOnEditMode() {
        #expect(custom(loadingAs: .flux3Klein) == nil)
        #expect(custom(loadingAs: .flux2Klein9B) == .img2img)
        #expect(custom(loadingAs: .krea2) == .img2img)
        #expect(custom(loadingAs: .qwen21Turbo) == .editReference)
    }

    /// Qwen-Image 2.1 has no img2img: the image becomes its next edit reference.
    @Test func qwenTakesAnEditReference() {
        #expect(input(.qwen21Turbo) == .editReference)
    }

    @Test func ideogramOffersNothing() {
        #expect(input(.ideogram4) == nil)
        #expect(input(.ideogram4, editMode: true) == nil)
    }

    @Test func theTitleNamesTheInput() {
        #expect(SourceImageInput.img2img.title == "Use as Img2Img Input")
        #expect(SourceImageInput.editReference.title == "Use as Edit Reference")
    }
}
