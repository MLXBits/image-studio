@testable import MLXBits_Image_Studio
import Testing

/// A gallery image picked as a source goes to the active model's input, so the
/// active model, not the image's, decides whether the item shows and what it says.
struct SourceImageInputTests {
    @Test(arguments: [
        FluxModelVariant.flux2Klein4B, .flux2Klein9B, .flux2KleinBase4B, .flux2KleinBase9B, .krea2, .zimage, .zimageTurbo,
    ])
    func img2imgModelsTakeAnImg2ImgSource(_ variant: FluxModelVariant) {
        #expect(SourceImageInput.forActive(variant, fluxEditMode: false) == .img2img)
    }

    /// Flux has both inputs: its edit mode takes references, not an img2img image.
    @Test(arguments: [FluxModelVariant.flux2Klein4B, .flux3Klein, .flux3KleinBase])
    func fluxEditModeTakesAnEditReference(_ variant: FluxModelVariant) {
        #expect(SourceImageInput.forActive(variant, fluxEditMode: true) == .editReference)
    }

    /// The edit-mode switch is Flux's alone.
    @Test(arguments: [FluxModelVariant.krea2, .zimage])
    func otherModelsIgnoreFluxEditMode(_ variant: FluxModelVariant) {
        #expect(SourceImageInput.forActive(variant, fluxEditMode: true) == .img2img)
    }

    /// FLUX 3 has no img2img mode: only Edit takes its reference images.
    @Test(arguments: [FluxModelVariant.flux3Klein, .flux3KleinBase])
    func flux3OffersNothingOutsideEditMode(_ variant: FluxModelVariant) {
        #expect(SourceImageInput.forActive(variant, fluxEditMode: false) == nil)
    }

    /// Qwen-Image 2.1 has no img2img: the image becomes its next edit reference.
    @Test func qwenTakesAnEditReference() {
        #expect(SourceImageInput.forActive(.qwen21Turbo, fluxEditMode: false) == .editReference)
    }

    @Test func ideogramOffersNothing() {
        #expect(SourceImageInput.forActive(.ideogram4, fluxEditMode: false) == nil)
        #expect(SourceImageInput.forActive(.ideogram4, fluxEditMode: true) == nil)
    }

    @Test func theTitleNamesTheInput() {
        #expect(SourceImageInput.img2img.title == "Use as Img2Img Input")
        #expect(SourceImageInput.editReference.title == "Use as Edit Reference")
    }
}
