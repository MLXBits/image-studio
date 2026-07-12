import Foundation

enum ModelFamily: String, CaseIterable, Codable {
    case flux = "FLUX.2"
    case ideogram4 = "Ideogram 4"
    case krea2 = "Krea 2"
    /// SeedVR2 upscaler. Not a model-picker family — it's an action applied to an
    /// existing image (see ``SeedVR2JobRunner``). Present only so its runner has a
    /// distinct ``GenerationCoordinator`` gate identity (serializes against the
    /// generative families — the OOM guard). Excluded from LoRA/generative UI.
    case seedvr2 = "SeedVR2"

    /// Families the user can pick and generate with (excludes the upscaler).
    static let generative: [Self] = [.flux, .ideogram4, .krea2]
}
