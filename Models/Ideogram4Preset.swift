import Foundation

enum Ideogram4Preset: String, CaseIterable, Codable, Hashable {
    case turbo = "V4_TURBO_12"
    case normal = "V4_DEFAULT_20"
    case quality = "V4_QUALITY_48"

    static func clampDimension(_ value: Int) -> Int {
        ((max(256, min(2048, value)) + 8) / 16) * 16
    }

    var displayName: String {
        switch self {
        case .turbo: "Turbo"
        case .normal: "Normal"
        case .quality: "Quality"
        }
    }

    var stepCount: Int {
        switch self {
        case .turbo: 12
        case .normal: 20
        case .quality: 48
        }
    }

    var labelWithSteps: String {
        "\(displayName) (\(stepCount))"
    }
}
