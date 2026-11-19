import Foundation

enum ModelFamily: String, CaseIterable, Codable {
    case flux = "FLUX.2"
    case ideogram4 = "Ideogram 4"
    case krea2 = "Krea 2"
    /// Z-Image family — the base Z-Image and the distilled Z-Image Turbo, which
    /// share one generation pipeline (see ``ZImageJobRunner``). The specific
    /// variant a job used is carried on ``ZImageJob/modelVariant``.
    case zimage = "Z-Image"
    /// Qwen-Image 2.1 Turbo: text-to-image and multi-reference edit through one
    /// CLI (`mflux-generate-qwen-2.1-edit`; no references = text-to-image).
    case qwen21 = "Qwen Image 2.1"
    /// SeedVR2 upscaler. Not a model-picker family — it's an action applied to an
    /// existing image (see ``SeedVR2JobRunner``). Present only so its runner has a
    /// distinct ``GenerationCoordinator`` gate identity (serializes against the
    /// generative families — the OOM guard). Excluded from LoRA/generative UI.
    case seedvr2 = "SeedVR2"

    /// Families the user can pick and generate with (excludes the upscaler).
    static let generative: [Self] = [.flux, .ideogram4, .krea2, .zimage, .qwen21]
    /// Whether the family has a source-image input the gallery's "Use as img2img"
    /// can feed: an img2img image (FLUX.2, Krea 2, Z-Image) or, for Qwen-Image 2.1,
    /// the edit-reference list. Ideogram 4 and the SeedVR2 action have none.
    var acceptsSourceImage: Bool {
        switch self {
        case .flux, .krea2, .zimage, .qwen21: true
        case .ideogram4, .seedvr2: false
        }
    }

    /// Stable, machine-safe identifier for use as a persisted-dictionary key (the
    /// `rawValue`s above are human display strings and contain spaces). The ComfyUI
    /// checkpoint store is keyed by this so the settings UI and the runner agree.
    var id: String {
        rawValue.replacingOccurrences(of: " ", with: "").lowercased()
    }
}

extension ModelFamily {
    /// The model that View ▸ Model (⌘1–5) selects for this family: the family's
    /// model last picked in this window, else the Settings default when it
    /// belongs to the family, else the family's first model. Nil for SeedVR2,
    /// which is not a pickable family. A custom checkpoint is never remembered.
    func variantToSelect(
        remembered: [Self: FluxModelVariant],
        defaultModel: FluxModelVariant
    ) -> FluxModelVariant? {
        if let last = remembered[self], last != .custom, last.family == self {
            return last
        }
        if defaultModel != .custom, defaultModel.family == self {
            return defaultModel
        }
        return switch self {
        case .flux: .flux2Klein9B
        case .ideogram4: .ideogram4
        case .krea2: .krea2
        case .zimage: .zimageTurbo
        case .qwen21: .qwen21Turbo
        case .seedvr2: nil
        }
    }
}
