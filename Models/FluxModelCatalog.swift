import Foundation

enum FluxModelVariant: String, CaseIterable, Codable, Hashable {
    case flux2Klein4B      = "flux2-klein-4b"
    case flux2Klein9B      = "flux2-klein-9b"
    case flux2KleinBase4B  = "flux2-klein-base-4b"
    case flux2KleinBase9B  = "flux2-klein-base-9b"
    case custom

    var displayName: String {
        switch self {
        case .flux2Klein4B:      return "FLUX.2 Klein 4B"
        case .flux2Klein9B:      return "FLUX.2 Klein 9B"
        case .flux2KleinBase4B:  return "FLUX.2 Klein Base 4B"
        case .flux2KleinBase9B:  return "FLUX.2 Klein Base 9B"
        case .custom:            return "Custom Model"
        }
    }

    var isDistilled: Bool {
        self == .flux2Klein4B || self == .flux2Klein9B
    }

    var defaultSteps: Int { isDistilled ? 4 : 50 }
    var defaultGuidance: Double { isDistilled ? 1.0 : 3.5 }
    var supportsNegativePrompt: Bool { !isDistilled }

    var approximateBF16SizeGB: Double {
        switch self {
        case .flux2Klein4B, .flux2KleinBase4B: return 15.0
        case .flux2Klein9B, .flux2KleinBase9B: return 35.0
        case .custom: return 0
        }
    }

    var recommendedQuantize: Int {
        switch self {
        case .flux2Klein4B, .flux2KleinBase4B: return 8
        case .flux2Klein9B, .flux2KleinBase9B: return 8
        case .custom: return 8
        }
    }

    var mfluxModelID: String { rawValue }

    static var builtIn: [FluxModelVariant] {
        [.flux2Klein9B, .flux2Klein4B, .flux2KleinBase9B, .flux2KleinBase4B]
    }
}