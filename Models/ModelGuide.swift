import Foundation

/// Plain-language teaching copy for one model, shown in the Models window.
nonisolated struct ModelGuide: Equatable, Sendable {
    let blurb: String
    let greatAt: [String]
    let note: String?
}

nonisolated extension FluxModelVariant {
    var guide: ModelGuide {
        switch self {
        case .flux2Klein4B:
            ModelGuide(
                blurb: """
                The smallest and fastest FLUX.2 model. It makes an image in 4 steps without a guidance setting, so \
                it suits quick drafts and large batches.
                """,
                greatAt: ["Fast drafts", "Batches", "Low memory"],
                note: nil
            )
        case .flux2Klein9B:
            ModelGuide(
                blurb: """
                The larger FLUX.2 Klein model, still 4 steps and guidance-free. It trades some speed for higher \
                quality than the 4B model.
                """,
                greatAt: ["Quality at speed", "Editing", "References"],
                note: nil
            )
        case .flux2KleinBase4B:
            ModelGuide(
                blurb: """
                The full-diffusion FLUX.2 Klein 4B. It runs about 50 steps with guidance, so it is slower \
                but gives you more control than the 4-step model.
                """,
                greatAt: ["Fine control", "Guidance", "Detail"],
                note: nil
            )
        case .flux2KleinBase9B:
            ModelGuide(
                blurb: """
                The full-diffusion FLUX.2 Klein 9B. About 50 steps with guidance, for the most control in the \
                FLUX.2 family at the cost of speed.
                """,
                greatAt: ["Fine control", "Guidance", "Detail"],
                note: nil
            )
        case .flux3Klein:
            ModelGuide(
                blurb: """
                A distilled FLUX.3 model that works best around 16 steps with no guidance setting. It reads long \
                prompts, up to about 4,000 tokens, and does text-to-image and multi-reference editing.
                """,
                greatAt: ["Long prompts", "Reference editing", "Quick results"],
                note: "FLUX.3 has no image-to-image mode. Use text-to-image or reference editing."
            )
        case .flux3KleinBase:
            ModelGuide(
                blurb: """
                The undistilled FLUX.3 Klein. It runs about 50 steps with guidance and also reads long prompts, so \
                it is slower than the distilled model but easier to steer.
                """,
                greatAt: ["Long prompts", "Guidance", "Fine control"],
                note: "FLUX.3 has no image-to-image mode. Use text-to-image or reference editing."
            )
        case .ideogram4:
            ModelGuide(
                blurb: """
                A model that takes a structured caption instead of a single prompt: a scene, an optional style, and \
                regional elements you can place with bounding boxes and color palettes.
                """,
                greatAt: ["Layout control", "Exact colors", "Structured captions"],
                note: """
                The Q8 and Q4 repos are gated on Hugging Face. Accept access on each repo page, then set a Hugging \
                Face token in Settings ▸ Advanced. BF16 is not gated.
                """
            )
        case .krea2:
            ModelGuide(
                blurb: """
                A few-step turbo model from Krea. It defaults to 8 steps with guidance at 1.0 and reads prompts up \
                to about 1,000 tokens.
                """,
                greatAt: ["Quick results", "Long prompts"],
                note: "A negative prompt works when guidance is above 1; at 1.0 it is not used."
            )
        case .zimageTurbo:
            ModelGuide(
                blurb: "A guidance-free turbo model that works well at 9 steps. It is the smaller, quicker Z-Image option.",
                greatAt: ["Fast results", "Low memory", "Quick drafts"],
                note: nil
            )
        case .zimage:
            ModelGuide(
                blurb: """
                The full Z-Image model. It runs about 50 steps with guidance and takes a negative prompt, so it is \
                slower than Turbo but lets you steer what to avoid.
                """,
                greatAt: ["Negative prompts", "Guidance", "Fine control"],
                note: "Takes a negative prompt. Z-Image Turbo has none."
            )
        case .qwen21Turbo:
            ModelGuide(
                blurb: """
                A distilled Qwen Image 2.1 that makes an image in 8 steps. One model handles both generating from a \
                prompt and editing an existing image.
                """,
                greatAt: ["Generate and Edit", "Quick results"],
                note: "Does both Generate and Edit with the same model."
            )
        case .custom:
            ModelGuide(
                blurb: """
                A model you point the app at yourself, such as a local folder or another Hugging Face repo. Settings \
                depend on what the model supports.
                """,
                greatAt: ["Your own models"],
                note: nil
            )
        }
    }
}
