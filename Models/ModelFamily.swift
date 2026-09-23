import Foundation

enum ModelFamily: String, CaseIterable, Codable {
    case flux = "FLUX.2"
    case ideogram4 = "Ideogram 4"
    case krea2 = "Krea 2"
    /// Z-Image family — the base Z-Image and the distilled Z-Image Turbo, which
    /// share one generation pipeline (see ``ZImageJobRunner``). The specific
    /// variant a job used is carried on ``ZImageJob/modelVariant``.
    case zimage = "Z-Image"
    /// Qwen-Image 2.1: a single guidance-free 7B DiT with a Qwen3-VL text encoder,
    /// driven by `mflux-generate-qwen-2.1` (see ``QwenImageJobRunner``). mflux ships
    /// no LoRA support for it, so it is left out of the LoRA surfaces
    /// (see ``supportsLoras``).
    case qwenImage = "Qwen-Image"
    /// SeedVR2 upscaler. Not a model-picker family — it's an action applied to an
    /// existing image (see ``SeedVR2JobRunner``). Present only so its runner has a
    /// distinct ``GenerationCoordinator`` gate identity (serializes against the
    /// generative families — the OOM guard). Excluded from LoRA/generative UI.
    case seedvr2 = "SeedVR2"

    /// Families the user can pick and generate with (excludes the upscaler).
    static let generative: [Self] = [.flux, .ideogram4, .krea2, .zimage, .qwenImage]
    /// Whether the family's mflux pipeline accepts LoRAs. Drives which families
    /// the LoRA library and stack editors offer.
    var supportsLoras: Bool {
        self != .qwenImage && self != .seedvr2
    }

    /// Stable, machine-safe identifier for use as a persisted-dictionary key (the
    /// `rawValue`s above are human display strings and contain spaces). The ComfyUI
    /// checkpoint store is keyed by this so the settings UI and the runner agree.
    var id: String {
        rawValue.replacingOccurrences(of: " ", with: "").lowercased()
    }
}
