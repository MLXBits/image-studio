import Foundation

/// The input a gallery or preview image goes into when the user picks it as a
/// source: the active model's img2img image, or its edit-reference list. The
/// active model decides, not the image's: any image can be a source, and it
/// goes where the form the user is looking at takes one.
enum SourceImageInput: Equatable {
    case img2img, editReference

    /// The source-image input of `variant`, the model the picker generates with
    /// (a custom checkpoint passes the variant it loads as). Flux has both, and
    /// its edit mode takes references; FLUX 3 has no img2img mode, so only its
    /// edit mode takes one. Ideogram 4 has none.
    static func forActive(_ variant: FluxModelVariant, fluxEditMode: Bool) -> Self? {
        switch variant.family {
        case .flux:
            if fluxEditMode {
                .editReference
            } else {
                variant.isFlux3 ? nil : .img2img
            }
        case .krea2, .zimage: .img2img
        case .qwen21: .editReference
        case .ideogram4, .seedvr2: nil
        }
    }

    /// The menu item's title.
    var title: String {
        switch self {
        case .img2img: "Use as Img2Img Input"
        case .editReference: "Use as Edit Reference"
        }
    }

    /// The icon button's help text and accessibility label.
    var help: String {
        switch self {
        case .img2img: "Use as img2img input"
        case .editReference: "Add as an edit reference"
        }
    }
}

/// The active family's source-image item, ready for a menu or a button: which
/// input it fills, and what choosing it does with an image's path.
struct SourceImageAction {
    let input: SourceImageInput
    let use: (String) -> Void
}
