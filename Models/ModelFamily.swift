import Foundation

nonisolated enum ModelFamily: String, CaseIterable, Codable {
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
    /// Stable, machine-safe identifier for use as a persisted-dictionary key (the
    /// `rawValue`s above are human display strings and contain spaces). The ComfyUI
    /// checkpoint store is keyed by this so the settings UI and the runner agree.
    var id: String {
        rawValue.replacingOccurrences(of: " ", with: "").lowercased()
    }
}

nonisolated extension ModelFamily {
    /// The file-name prefix the gallery files this family's images by, lowercased.
    /// Flux's outputs ("image_…") have none: a name no family claims is Flux's.
    /// Looser than the runners' `outputPrefix` on purpose: "ideogram" also matches
    /// files saved before Ideogram 4 wrote "ideogram4_".
    var galleryFilePrefix: String? {
        switch self {
        case .flux: nil
        case .ideogram4: "ideogram"
        case .krea2: "krea2"
        case .zimage: "zimage"
        case .qwen21: "qwen21"
        case .seedvr2: "seedvr2"
        }
    }

    /// The picker family a lowercased gallery file name says, else Flux. An
    /// upscale's family is its source's (``GalleryItem/modelFamily``), not this.
    init(galleryFileName name: String) {
        let claimed = Self.allCases.first { family in
            family != .seedvr2 && family.galleryFilePrefix.map { name.hasPrefix($0) } == true
        }
        self = claimed ?? .flux
    }
}

nonisolated extension SidecarFamily {
    /// The family that wrote a sidecar tagged with this.
    var modelFamily: ModelFamily {
        switch self {
        case .flux: .flux
        case .ideogram4: .ideogram4
        case .krea2: .krea2
        case .zimage: .zimage
        case .qwen21: .qwen21
        case .seedvr2: .seedvr2
        }
    }
}
